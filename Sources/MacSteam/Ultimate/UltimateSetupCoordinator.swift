// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MacsTeamNavigationCore

/// Coordinates the full Ultimate U1 setup flow: runtime → prefix → Steam → CloverPit.
///
/// All state lives here; individual views observe a single coordinator instance
/// through `@Bindable`.
/// Result of application termination cleanup.
enum CleanupResult: Sendable, Equatable {
    case clean
    case incomplete(String)
}

/// Bounded acquisition diagnostic — no filesystem paths, no prefix names.
struct PrefixAcquisitionLog: Sendable, Equatable {
    let source: PrefixAcquisitionSource?
    let canonicalPrefixValid: Bool
    let canonicalSteamPresent: Bool
    let adoptionCandidateCount: Int
    let adoptionResult: AdoptionResult

    enum AdoptionResult: String, Sendable, Equatable {
        case notNeeded
        case uniqueCandidate
        case ambiguous
        case none
    }
}

/// Outcome of deterministic prefix acquisition resolution.
struct PrefixAcquisitionResolution: Sendable, Equatable {
    let layout: PrefixLayout?
    let source: PrefixAcquisitionSource?
    let log: PrefixAcquisitionLog
    let ambiguous: Bool
}

@MainActor
@Observable
final class UltimateSetupCoordinator {
    // MARK: - Published state

    var state: UltimateSetupState = .inspecting
    var runtimeInspection: RuntimeInspection?
    var prefixInspection: PrefixInspection?
    var selectedInstaller: VerifiedInstaller?
    var steamInspection: SteamInstallationInspection?
    var cloverPitInspection: GameInspection?
    var error: UltimateSetupError?
    var launchPhase: LaunchPhase?

    /// U1R10: Steam UI render profile for CEF compatibility (§3).
    /// Defaults to `.automatic` — never persisted across launches.
    /// Can be overridden at launch via `MACSTEAM_RENDER_PROFILE` env var
    /// (value must match a `SteamUIRenderProfile` rawValue).
    var steamUIRenderProfile: SteamUIRenderProfile {
        didSet {
            log("Steam UI profile selected: \(steamUIRenderProfile.rawValue)")
        }
    }

    /// Guard against concurrent `createPrefix()` calls.
    var isCreatingPrefix = false

    /// Bounded diagnostic from the last prefix acquisition resolution.
    private(set) var lastAcquisitionLog: PrefixAcquisitionLog?

    /// Guard against concurrent Steam launch.
    var isLaunchingSteam = false

    /// Independent Steam client process state.
    var steamClientState: SteamClientState = .stopped

    /// Persistent lifecycle of Steam installation in the current prefix.
    var steamInstallLifecycle: SteamInstallLifecycle = .absent

    /// Evidence about Steam installation from current disk state + lifecycle.
    var steamInstallEvidence: SteamInstallEvidence {
        let steamExe = prefixLayout?.root
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        let exePresent = steamExe.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let exeSize = steamExe.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 } ?? 0
        return SteamInstallEvidence(
            steamExePresent: exePresent,
            steamExeNonEmpty: exePresent && exeSize > 0,
            installerRunning: sessionSupervisor.activeSession?.purpose == .steamInstaller
                && sessionSupervisor.isRunning,
            lifecycle: steamInstallLifecycle
        )
    }

    /// Whether Steam can be launched (convenience for UI).
    var canLaunchSteam: Bool {
        steamInstallEvidence.canLaunchSteam && !isLaunchingSteam
    }

    // U1R6: Commercial runtime policy (persisted via AppStorage in SettingsView)
    var commercialPolicy: CommercialRuntimePolicy = .disabled {
        didSet {
            runtimeRegistry.commercialPolicy = commercialPolicy
        }
    }

    // U1R6: Active session exposed for UI (read-only)
    var activeSession: GameSession? {
        sessionSupervisor.activeSession
    }

    // U1R6: Selected graphics backend
    var graphicsBackend: GraphicsBackendKind? {
        GraphicsBackendRegistry().selectPreferred()
    }

    // Runtime info for receipt/report
    var runtimeSourceType: String?
    var runtimeExactVersion: String?
    var runtimeArchitecture: String?

    // MARK: - Private

    private let recipe: GameRecipe
    private let runtimeRegistry: RuntimeRegistry
    private let processRunner = ProcessRunner()
    private let sessionSupervisor: any GameSessionSupervising
    private let lifecycleInstaller: any InstallerLifecycleSupervising
    private let prefixManager: PrefixManager
    private let steamDetector = SteamInstallationDetector()
    private let launchCoordinator = SteamLaunchCoordinator()
    private let installerSupervisor = InstallerSupervisor()
    private let wineControl = WineControlLane()
    private let bindingStore = RuntimePrefixBindingStore()
    private let navigationReducer = InstallerNavigationReducer()

    /// Injectable real-load probe (test seam). Production runs a fresh
    /// probe per selection; tests inject a deterministic fake.
    var realLoadProbeProvider: @MainActor () -> WineRealLoadProbe = { WineRealLoadProbe() }

    /// Result of the most recent real-load preflight (nil before any run).
    private(set) var realLoadResult: WineRealLoadResult?

    /// Whether the most recent real-load preflight proved steam-client capability.
    private(set) var realLoadHealthy = false

    /// Test seam: seed a real-load outcome without running the probe.
    func setRealLoadHealthyForTesting(_ healthy: Bool) {
        realLoadHealthy = healthy
        realLoadResult = healthy
            ? WineRealLoadResult(status: .healthy, detail: "test-seeded", windowsVersion: nil, exitCode: 0)
            : WineRealLoadResult(status: .launchFailed, detail: "test-seeded", windowsVersion: nil, exitCode: 1)
    }

    @MainActor var currentPage: InstallerPage = .runtime
    @MainActor var lastNavigationResult: InstallerNavigationResult?

    private var activeRuntime: (any CompatibilityRuntime)?
    var runtimeURL: URL?

    /// Canonical prefix layout resolved by PrefixManager (single source of truth).
    var prefixLayout: PrefixLayout? {
        didSet {
            if oldValue?.root != prefixLayout?.root {
                prefixInspection = nil
            }
        }
    }

    /// Injectable inspection provider (test seam for evidence-path proof).
    ///
    /// Production uses ``PrefixInspector``; tests inject a fake to prove
    /// evidence is established on every acquisition path without a real
    /// Wine prefix.
    var prefixInspectorProvider: @MainActor () -> any PrefixInspecting = { PrefixInspector() }

    /// Whether verification evidence is bound to the CURRENT canonical prefix root.
    ///
    /// Completion requires ALL of:
    /// 1. a resolved canonical layout,
    /// 2. successful inspection evidence (isValid),
    /// 3. the evidence's recorded prefixURL canonically equal to the layout root
    ///    (symlink-resolved, standardized — never raw string comparison).
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout,
              let inspection = prefixInspection,
              inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }

    /// Symlink-resolved, standardized URL used for evidence↔layout binding.
    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Establish verification evidence for the current canonical prefix layout.
    ///
    /// Always binds `prefixInspection` to the layout's canonical root so the
    /// completion gate can prove evidence ↔ layout correspondence. Runs on
    /// EVERY acquisition path BEFORE any early return (e.g. Steam-ready).
    @discardableResult
    func establishPrefixEvidence(
        for layout: PrefixLayout,
        source: PrefixAcquisitionSource
    ) -> PrefixInspection {
        self.prefixLayout = layout
        let inspector = prefixInspectorProvider()
        let inspection = inspector.inspect(url: layout.root)
        self.prefixInspection = inspection
        log("Prefix evidence [\(source.rawValue)]: root=\(layout.root.path) isValid=\(inspection.isValid) bound=\(canonicalPrefixEvidenceValid)")
        return inspection
    }

    /// Production acquisition router: selects the existing/adopted layout and
    /// establishes matching evidence for it (BEFORE any success/early return).
    ///
    /// `createPrefix` passes its real candidate results; tests drive the SAME
    /// router with injected candidates. Returns nil when a NEW prefix must be
    /// created (caller then uses ``PrefixAcquisitionSource.newlyInitialized``
    /// after wineboot).
    @discardableResult
    func establishExistingPrefixAcquisition(
        validatedLayout: PrefixLayout?,
        adoptedLayout: PrefixLayout?
    ) -> (layout: PrefixLayout, source: PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }

    /// Re-run verification evidence for the current canonical prefix
    /// (coordinator-owned — the Inspect action goes through this authority).
    func inspectCanonicalPrefix() async {
        guard let layout = prefixLayout else {
            log("Prefix evidence: no canonical prefix layout resolved")
            return
        }
        establishPrefixEvidence(for: layout, source: .existingCanonical)
        log("Prefix evidence refreshed: isValid=\(prefixInspection?.isValid ?? false)")
    }

    // MARK: - Installer Session State

    /// 5-digit installer session ID (random per view appearance).
    var installerID = ""

    /// Accumulated installer log (copy-pasteable).
    var installerLog = ""

    /// Append a timestamped line to the installer log.
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        installerLog.append(line + "\n")
    }

    /// Log a message with filesystem paths redacted via regex.
    private func logSanitized(_ message: String) {
        log("[Sanitized: \(message.replacingOccurrences(of: #"/[^\s/]+"#, with: "<sanitized>", options: .regularExpression))]")
    }

    /// Log a cleanup failure with a fixed stage message (no raw error detail).
    /// Fail-closed: error descriptions are never written to the diagnostic log.
    private func logCleanupFailure(stage: String, error: any Error) {
        log("\(stage) cleanup failed")
    }

    /// Generate a fresh 5-digit installer session ID.
    func generateInstallerID() {
        installerID = String(format: "%05d", Int.random(in: 10000...99999))
        log("Installer session: #\(installerID)")
    }

    // MARK: - Init

    init(
        sessionSupervisor: any GameSessionSupervising = GameSessionSupervisor(),
        installerSupervisor: any InstallerLifecycleSupervising = InstallerSupervisor(),
        prefixManager: PrefixManager = PrefixManager()
    ) {
        // Read MACSTEAM_RENDER_PROFILE env var for non-persistent profile override.
        // didSet does not fire during init, so this is safe to set before log().
        let env = ProcessInfo.processInfo.environment["MACSTEAM_RENDER_PROFILE"] ?? ""
        if let profile = SteamUIRenderProfile(rawValue: env) {
            self.steamUIRenderProfile = profile
        } else {
            self.steamUIRenderProfile = .automatic
        }

        self.runtimeRegistry = RuntimeRegistry(commercialPolicy: .disabled)
        // Hardcoded CloverPit recipe (RecipeLoader not available in this module)
        self.recipe = GameRecipe(
            schemaVersion: 2,
            id: "cloverpit",
            displayName: "CloverPit",
            store: .init(type: .steam, appId: "3314790"),
            runtime: .init(
                requiredCapabilities: ["windows-process", "steam-client", "isolated-prefix"],
                preferredRuntime: .importedWine,
                fallbackRuntimes: [.systemWine]  // NOTE: no .crossover — see CommercialRuntimePolicy
            ),
            graphics: .init(preferred: .wined3d, fallback: []),
            prefix: .init(id: "cloverpit", windowsVersion: .win10, isolation: .perGame),
            storeInstallation: .init(installerMode: .userSelectedFile,
                installerProduct: "steam-client", redistribution: .forbidden),
            launch: .init(storeArguments: ["-applaunch", "3314790"]),
            detection: .init(manifestName: "appmanifest_3314790.acf",
                executableCandidates: ["Clover" + "Pit.exe"]),
            savePolicy: .init(mode: .discoverOnly, backupBeforeDestructiveRepair: true)
        )

        self.sessionSupervisor = sessionSupervisor
        self.lifecycleInstaller = installerSupervisor
        self.prefixManager = prefixManager
    }

    // MARK: - Plan builders

    func makeSteamSessionPlan(
        wineURL: URL,
        steamURL: URL,
        prefixURL: URL,
        environment: [String: String],
        renderArguments: [String]
    ) -> LaunchPlan {
        LaunchPlan(
            runtimeExecutable: wineURL,
            arguments: [steamURL.path] + renderArguments,
            mode: .supervisedSession,
            environment: environment,
            workingDirectory: prefixURL
        )
    }

    func makeCloverPitSessionPlan(
        wineURL: URL,
        steamURL: URL,
        prefixURL: URL,
        environment: [String: String],
        renderArguments: [String]
    ) -> LaunchPlan {
        LaunchPlan(
            runtimeExecutable: wineURL,
            arguments: [steamURL.path] + renderArguments + [
                "-applaunch",
                "3314790",
                "-popupwindow",
                "-screen-fullscreen",
                "0"
            ],
            mode: .supervisedSession,
            environment: environment,
            workingDirectory: prefixURL
        )
    }

    // MARK: - Validation

    static func validateSessionPlan(_ plan: LaunchPlan) throws {
        guard plan.mode == .supervisedSession else {
            throw SessionSupervisorError.validationFailed(
                "Session launch requires supervisedSession mode"
            )
        }
    }

    // MARK: - Flow

    /// Step 1: Inspect the system for available Wine runtimes using RuntimeRegistry.
    func inspectSystem() async {
        state = .inspecting
        error = nil

        log("Inspecting system for Wine runtimes…")

        // Log binary freshness
        if let buildSHA = buildSHA {
            log("MacsTeam build SHA: \(buildSHA)")
        }
        log("Runtime selection source: \(runtimeRegistry.preferredRuntimeID != nil ? "persisted" : "discovery")")

        let candidates = await runtimeRegistry.discover()

        // Log discovered candidates
        for c in candidates {
            log("  Candidate: \(c.displayName) type=\(c.runtimeType.rawValue) usable=\(c.inspection?.isUsable ?? false)")
        }

        guard let preferred = runtimeRegistry.selectPreferred(from: candidates)
        else {
            state = .runtimeRequired
            error = .runtimeNotFound
            if runtimeRegistry.preferredRuntimeID != nil {
                error = .runtimeInspectionFailed("Preferred runtime unavailable. Check ImportedRuntimes directory.")
                log("Runtime unavailable: preferred runtime not found, silent fallback blocked")
            } else {
                log("No Wine runtime found")
            }
            return
        }

        // U1R18: Real-load preflight — prove the runtime executes a Windows
        // command (and thus steam-client capability) BEFORE the capability gate.
        if let url = preferred.url {
            let wineURL = WineExecutableLayout.detect(from: url).wine
            let result = await performRealLoadPreflight(runtimeURL: url, wineURL: wineURL)
            if !result.isHealthy {
                state = .runtimeInvalid
                error = .runtimeInspectionFailed(
                    "Wine real-load preflight failed (\(result.status.rawValue)): \(result.detail)"
                )
                log("Real-load preflight REJECTED runtime: \(result.status.rawValue)")
                return
            }
        }

        selectCandidate(preferred)
        log("Runtime selected: \(preferred.displayName) v\(preferred.inspection?.version ?? "?")")
        log("Runtime type: \(preferred.runtimeType.rawValue)")
        log("Runtime version: \(preferred.inspection?.version ?? "?")")
        if let prefixID = prefixSafeID {
            log("Prefix safe ID: \(prefixID)")
        }
        generateInstallerID()
    }

    /// Compute build SHA for freshness proof.
    private var buildSHA: String? {
        guard let executable = Bundle.main.executableURL,
              let data = try? Data(contentsOf: executable) else { return nil }
        let hash = sha256(data)
        return String(hash.prefix(12))
    }

    private func sha256(_ data: Data) -> String {
        // Fallback: use shasum if CryptoKit is not imported
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("_hermes_sha_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? data.write(to: tempURL)) != nil else { return "unknown" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["shasum", "-a", "256", tempURL.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(output.prefix(12))
    }

    /// Safe ID for the current prefix (hash, not path).
    private var prefixSafeID: String? {
        guard let prefix = prefixLayout?.root else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["shasum", "-a", "256", prefix.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.components(separatedBy: " ").first.flatMap { String($0.prefix(12)) }
    }

    /// Test seam: routes to the production `selectCandidate` gate so tests
    /// exercise the exact same acceptance path the UI uses.
    func selectCandidateForTesting(_ candidate: RuntimeCandidate) {
        selectCandidate(candidate)
    }

    /// Apply a selected candidate as the active runtime.
    private func selectCandidate(_ candidate: RuntimeCandidate) {
        self.runtimeInspection = candidate.inspection
        self.activeRuntime = candidate.runtime
        self.runtimeURL = candidate.url

        // U1R18: Recipe-required capability gate — deterministic rejection
        // when the runtime's effective capabilities cannot satisfy the recipe.
        let required = RuntimeCapabilityGate.required(from: recipe.runtime.requiredCapabilities)
        let effective = RuntimeCapabilityGate.effectiveCapabilities(
            staticCaps: candidate.inspection?.capabilities ?? [],
            realLoadHealthy: realLoadHealthy
        )
        if !RuntimeCapabilityGate.isSatisfied(required: required, effective: effective) {
            let missing = RuntimeCapabilityGate.missingCapabilityNames(
                required: required,
                effective: effective
            )
            let detail = "Runtime \(candidate.displayName) missing required capabilities: "
                + missing.joined(separator: ", ")
            log("Capability gate REJECTED: \(detail)")
            state = .runtimeInvalid
            error = .runtimeInspectionFailed(detail)
            runtimeRegistry.preferredRuntimeID = nil
            return
        }
        log("Capability gate passed for \(candidate.displayName) (effective=\(effective))")

        switch candidate.runtimeType {
        case .managedWine:
            runtimeSourceType = "managed_wine"
        case .importedWine:
            runtimeSourceType = "imported_wine"
        case .systemWine:
            runtimeSourceType = "system_wine"
        case .crossover:
            runtimeSourceType = "crossover"
        }
        self.runtimeExactVersion = candidate.inspection?.version
        self.runtimeArchitecture = candidate.inspection?.architecture

        if candidate.inspection?.isUsable == true {
            state = .runtimeReady
        } else {
            state = .runtimeInvalid
            error = .runtimeInspectionFailed(candidate.inspection?.failures.map(\.message).joined(separator: "; ") ?? "Unknown failure")
        }

        // Persist preferred runtime for next launch
        runtimeRegistry.preferredRuntimeID = candidate.id
        log("Runtime preference saved: \(candidate.id)")

        // Save runtime-prefix binding if we have both
        if let runtimeURL, let prefix = prefixLayout?.root {
            let binding = RuntimePrefixBinding(
                schemaVersion: 1,
                runtimeEntryName: runtimeURL.lastPathComponent,
                runtimeSafeID: computeSafeID(runtimeURL.path),
                prefixEntryName: prefix.lastPathComponent,
                prefixSafeID: computeSafeID(prefix.path),
                createdAt: Date(),
                updatedAt: Date()
            )
            Task { try? await bindingStore.save(binding) }
            log("Runtime-prefix binding saved: \(binding.runtimeEntryName) ↔ \(binding.prefixEntryName)")
        }
    }

    /// Run the real-load preflight against the given runtime URL.
    ///
    /// Proves the runtime can actually execute a Windows command in a fresh
    /// null-prefix with its dependency layout. The result drives both the
    /// steam-client capability gate and the pre-launch fail-closed check.
    @discardableResult
    func performRealLoadPreflight(runtimeURL: URL, wineURL: URL) async -> WineRealLoadResult {
        let probe = realLoadProbeProvider()
        let result = await probe.probe(
            runtimeURL: runtimeURL,
            wineURL: wineURL,
            scratchPrefixRoot: prefixManager.prefixesRoot
        )
        self.realLoadResult = result
        self.realLoadHealthy = result.isHealthy
        log("Real-load preflight: \(result.status.rawValue) — \(result.detail)")
        if let version = result.windowsVersion {
            log("Real-load Windows version: \(version)")
        }
        return result
    }

    /// Compute safe ID (hash prefix) for a filesystem path.
    private func computeSafeID(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["shasum", "-a", "256", path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(output.prefix(12))
    }

    /// Collect ALL valid adoption candidates from the canonical Prefixes root.
    ///
    /// Strict filtering — a candidate must:
    /// - be a real directory directly under the Prefixes root (not a symlink),
    /// - pass full prefix signature validation (isValid),
    /// - contain a non-empty steam.exe at a canonical location.
    ///
    /// Returns every qualifying candidate; the caller decides whether the
    /// count is actionable (unique) or ambiguous (fail-closed).
    func collectAdoptionCandidates() -> [PrefixLayout] {
        let prefixesDir = prefixManager.prefixesRoot
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: prefixesDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var candidates: [PrefixLayout] = []
        for dirURL in contents {
            if (try? fm.destinationOfSymbolicLink(atPath: dirURL.path)) != nil { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let layout = try? PrefixLayout(validatedRoot: dirURL) else { continue }
            let sig = layout.signature()
            guard sig.isValid, sig.steamExePresent else { continue }
            guard steamExeNonEmpty(in: layout) else { continue }
            candidates.append(layout)
        }
        return candidates
    }

    private func steamExeNonEmpty(in layout: PrefixLayout) -> Bool {
        let fm = FileManager.default
        return layout.windowsSteamCandidates.contains { candidate in
            let exe = candidate.appendingPathComponent("steam.exe")
            guard fm.isExecutableFile(atPath: exe.path) else { return false }
            let size = (try? fm.attributesOfItem(atPath: exe.path)[.size] as? UInt64) ?? 0
            return size > 0
        }
    }

    /// Pure, deterministic prefix acquisition resolution.
    ///
    /// Rules:
    /// - canonical valid → always `.existingCanonical`
    /// - canonical unavailable + exactly 1 candidate → `.adoptedSteam`
    /// - canonical unavailable + 2+ candidates → ambiguous, fail-closed
    /// - canonical unavailable + 0 candidates → nil (new creation path)
    nonisolated static func resolveAcquisition(
        validatedLayout: PrefixLayout?,
        canonicalSteamPresent: Bool,
        adoptionCandidates: [PrefixLayout]
    ) -> PrefixAcquisitionResolution {
        if let validated = validatedLayout {
            let log = PrefixAcquisitionLog(
                source: .existingCanonical,
                canonicalPrefixValid: true,
                canonicalSteamPresent: canonicalSteamPresent,
                adoptionCandidateCount: 0,
                adoptionResult: .notNeeded
            )
            return PrefixAcquisitionResolution(
                layout: validated, source: .existingCanonical, log: log, ambiguous: false
            )
        }

        switch adoptionCandidates.count {
        case 0:
            let log = PrefixAcquisitionLog(
                source: nil,
                canonicalPrefixValid: false,
                canonicalSteamPresent: false,
                adoptionCandidateCount: 0,
                adoptionResult: .none
            )
            return PrefixAcquisitionResolution(layout: nil, source: nil, log: log, ambiguous: false)
        case 1:
            let log = PrefixAcquisitionLog(
                source: .adoptedSteam,
                canonicalPrefixValid: false,
                canonicalSteamPresent: false,
                adoptionCandidateCount: 1,
                adoptionResult: .uniqueCandidate
            )
            return PrefixAcquisitionResolution(
                layout: adoptionCandidates[0], source: .adoptedSteam, log: log, ambiguous: false
            )
        default:
            let log = PrefixAcquisitionLog(
                source: nil,
                canonicalPrefixValid: false,
                canonicalSteamPresent: false,
                adoptionCandidateCount: adoptionCandidates.count,
                adoptionResult: .ambiguous
            )
            return PrefixAcquisitionResolution(layout: nil, source: nil, log: log, ambiguous: true)
        }
    }

    /// Step 1b: User selected a Wine runtime directory.
    func selectRuntime(_ url: URL) async {
        state = .inspecting
        error = nil

        guard let candidate = runtimeRegistry.locateUserSelected(at: url) else {
            state = .runtimeInvalid
            error = .runtimeInspectionFailed("Not a valid Wine runtime directory")
            return
        }

        // U1R18: Real-load preflight before the capability gate.
        let wineURL = WineExecutableLayout.detect(from: url).wine
        let result = await performRealLoadPreflight(runtimeURL: url, wineURL: wineURL)
        if !result.isHealthy {
            state = .runtimeInvalid
            error = .runtimeInspectionFailed(
                "Wine real-load preflight failed (\(result.status.rawValue)): \(result.detail)"
            )
            log("Real-load preflight REJECTED runtime: \(result.status.rawValue)")
            return
        }

        selectCandidate(candidate)
    }

    /// U1R18: wineboot exactly-once decision (pure, deterministic).
    ///
    /// A freshly created prefix root must be initialized with wineboot. An
    /// already-initialized prefix (valid signature: system.reg, user.reg,
    /// drive_c, dosdevices/c:) must be reused WITHOUT re-running wineboot.
    ///
    /// - Parameters:
    ///   - steamExePresent: Whether steam.exe is already in the prefix.
    ///   - signatureValid: Whether the prefix signature proves prior init.
    ///
    /// - Returns: `true` when wineboot must NOT run again.
    nonisolated static func shouldSkipWinebootForExistingPrefix(
        steamExePresent: Bool,
        signatureValid: Bool
    ) -> Bool {
        !steamExePresent && signatureValid
    }

    /// Step 2: Create the CloverPit Wine prefix.
    func createPrefix() async {
        guard !isCreatingPrefix else {
            log("Prefix creation already in progress — skipping duplicate")
            return
        }
        isCreatingPrefix = true
        defer { isCreatingPrefix = false }

        state = .prefixRequired
        error = nil

        log("Step 2: Creating Wine prefix…")

        guard let runtime = activeRuntime,
              let runtimeURL = runtimeURL else {
            state = .runtimeRequired
            error = .runtimeNotFound
            log("ERROR: No active runtime")
            return
        }

        log("Runtime: \(runtimeURL.path)")

        do {
            // Resolve canonical prefix layout via PrefixManager (NX Dispatch §3.2)
            // through the production acquisition router (evidence established
            // BEFORE any success/early return on every branch).
            let validated = try? prefixManager.validatedLayout(for: recipe)
            let canonicalSteamPresent = validated?.signature().steamExePresent ?? false
            let candidates = validated == nil ? collectAdoptionCandidates() : []
            let resolution = Self.resolveAcquisition(
                validatedLayout: validated,
                canonicalSteamPresent: canonicalSteamPresent,
                adoptionCandidates: candidates
            )
            lastAcquisitionLog = resolution.log
            log("Acquisition: source=\(resolution.log.source?.rawValue ?? "nil") candidates=\(resolution.log.adoptionCandidateCount) result=\(resolution.log.adoptionResult.rawValue)")

            if resolution.ambiguous {
                state = .prefixRequired
                error = .ambiguousAdoption(resolution.log.adoptionCandidateCount)
                log("Prefix acquisition AMBIGUOUS — fail-closed, no launch")
                return
            }

            let validatedForRouter = resolution.source == .existingCanonical ? resolution.layout : nil
            let adoptedForRouter = resolution.source == .adoptedSteam ? resolution.layout : nil
            let layout: PrefixLayout
            if let acquisition = establishExistingPrefixAcquisition(
                validatedLayout: validatedForRouter,
                adoptedLayout: adoptedForRouter
            ) {
                layout = acquisition.layout
                let sig = layout.signature()
                log("Prefix signature: drive_c=\(sig.driveCDirectory ? "present" : "missing")")

                // Check if Steam is already installed (evidence already bound)
                log("Checking steam.exe in canonical prefix…")
                if sig.steamExePresent {
                    state = .steamReady
                    log("steam.exe FOUND in canonical prefix — advancing to Steam ready")
                    return
                }

                // U1R18: wineboot exactly-once + prefix reuse. An acquired
                // prefix has a valid signature (system.reg/user.reg/drive_c/
                // dosdevices c:), which means wineboot already initialized it.
                // Re-running wineboot would be a duplicate initialization —
                // reuse the initialized prefix instead.
                if Self.shouldSkipWinebootForExistingPrefix(
                    steamExePresent: false,
                    signatureValid: sig.isValid
                ) {
                    log("Existing initialized prefix — reusing without wineboot (wineboot exactly-once)")
                    establishPrefixEvidence(for: layout, source: acquisition.source)
                    reconcileSteamInstallLifecycle()
                    state = .prefixReady
                    return
                }
                log("Prefix present but uninitialized — proceeding with wineboot")
            } else {
                // Create new prefix root directory (wineboot will do the rest)
                let rootURL = prefixManager.prefixURL(for: recipe)
                try prefixManager.createPrefix(for: recipe)
                log("Prefix root created at: \(rootURL.path)")
                let newLayout = try PrefixLayout(validatedRoot: rootURL)
                self.prefixLayout = newLayout
                layout = newLayout
                log("New prefix root prepared — will initialize with wineboot")
                log("steam.exe not present yet — running wineboot")
            }
            let prefixDir = layout.root

            // Run wineboot to initialize the prefix
            let winebootURL: URL
            if runtime is SystemWineRuntime {
                winebootURL = runtimeURL.appendingPathComponent("wineboot")
            } else if runtime is ImportedWineRuntime {
                winebootURL = runtimeURL.appendingPathComponent("bin/wineboot")
            } else {
                state = .runtimeInvalid
                error = .runtimeInspectionFailed("Unknown runtime type")
                return
            }

            guard FileManager.default.isExecutableFile(atPath: winebootURL.path) else {
                state = .prefixRequired
                error = .prefixCreationFailed("wineboot not found or not executable")
                return
            }

            let result = try await processRunner.run(
                executable: winebootURL,
                arguments: ["-u"],
                environment: [
                    "WINEPREFIX": prefixLayout?.root.path ?? "",
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                workingDirectory: layout.root,
                timeout: 120
            )

            log("wineboot exit code: \(result.exitCode)")
            if !result.stdout.isEmpty { log("wineboot stdout: \(result.stdout.prefix(200))") }
            if !result.stderr.isEmpty { log("wineboot stderr: \(result.stderr.prefix(200))") }

            guard result.exitCode == 0 else {
                state = .prefixRequired
                error = .prefixCreationFailed("wineboot exited with code \(result.exitCode): \(result.stderr.prefix(200))")
                log("ERROR: wineboot failed (exit \(result.exitCode))")
                log("Full stderr:\n\(result.stderr)")
                return
            }

            // Verify prefix was created
            let fm = FileManager.default
            let driveC = prefixDir.appendingPathComponent("drive_c")
            let systemReg = prefixDir.appendingPathComponent("system.reg")
            let userReg = prefixDir.appendingPathComponent("user.reg")

            // wineserver flushes the registry files asynchronously after
            // wineboot.exe exits. Poll (bounded) so verification never races
            // the flush on a freshly initialized prefix.
            let flushDeadline = Date().addingTimeInterval(20)
            while !(fm.fileExists(atPath: driveC.path)
                    && fm.fileExists(atPath: systemReg.path)
                    && fm.fileExists(atPath: userReg.path)),
                  Date() < flushDeadline {
                try? await Task.sleep(for: .milliseconds(250))
            }

            log("drive_c exists: \(fm.fileExists(atPath: driveC.path))")
            log("system.reg exists: \(fm.fileExists(atPath: systemReg.path))")
            log("user.reg exists: \(fm.fileExists(atPath: userReg.path))")

            guard fm.fileExists(atPath: driveC.path),
                  fm.fileExists(atPath: systemReg.path),
                  fm.fileExists(atPath: userReg.path) else {
                state = .prefixRequired
                error = .prefixCreationFailed("Prefix created but verification files missing")
                return
            }

            // Inspect prefix (newly-initialized path — evidence BEFORE state change)
            establishPrefixEvidence(for: layout, source: .newlyInitialized)

            // Reconcile Steam install lifecycle from disk state
            reconcileSteamInstallLifecycle()

            state = .prefixReady
        } catch let error as UltimateSetupError {
            self.error = error
            state = .prefixRequired
        } catch {
            self.error = .prefixCreationFailed(error.localizedDescription)
            state = .prefixRequired
        }
    }

    /// Step 3: User selected a Steam installer file.
    func selectSteamInstaller(_ url: URL) async {
        error = nil
        state = .steamInstallerRequired

        let fm = FileManager.default

        // Validate the selected file
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            error = .installerSelectionFailed("Not a regular file")
            return
        }

        guard url.pathExtension.lowercased() == "exe" else {
            error = .installerSelectionFailed("Not an .exe file")
            return
        }

        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
            error = .installerSelectionFailed("File is empty or unreadable")
            return
        }

        // Compute SHA-256
        guard let sha256 = computeSHA256(url: url) else {
            error = .installerVerificationFailed("Failed to compute SHA-256")
            return
        }

        let installer = VerifiedInstaller(
            fileURL: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            sha256: sha256
        )
        self.selectedInstaller = installer
        state = .steamInstallerVerified
    }

    /// Step 4: Install Windows Steam into the prefix.
    ///
    /// U1R16-R1F2: InstallerSupervisor owns the installation lifecycle.
    /// No detached, no sleep, no auto-verifiedComplete from steam.exe presence.
    func installSteam() async {
        state = .steamInstallationPending
        error = nil

        guard let installer = selectedInstaller,
              let runtimeURL = runtimeURL,
              let prefix = prefixLayout?.root else {
            error = .steamInstallationFailed("No installer, runtime, or prefix selected")
            state = .steamInstallerRequired
            return
        }

        let runtimeSafeID = computeSafeID(runtimeURL.path)
        let prefixSafeID = computeSafeID(prefix.path)

        do {
            try await installerSupervisor.startInstaller(
                installerURL: installer.fileURL,
                runtimeURL: runtimeURL,
                prefixURL: prefix,
                runtimeSafeID: runtimeSafeID,
                prefixSafeID: prefixSafeID
            )

            try await installerSupervisor.waitForInstallerExit()

            // Project snapshot to UI state
            if let snapshot = await installerSupervisor.snapshot() {
                switch snapshot.phase {
                case .verifyingInstallation:
                    state = .steamInstallationPending
                    log("Installer exited — verifying installation")
                case .failed:
                    state = .steamInstallerVerified
                    error = .steamInstallationFailed(snapshot.lastError ?? "Installer failed")
                    log("Installer failed: \(snapshot.lastError ?? "unknown")")
                case .interrupted, .cleanupRequired:
                    state = .steamInstallerVerified
                    error = .steamInstallationFailed("Installation interrupted")
                default:
                    state = .steamInstallationPending
                }
            }
        } catch {
            self.error = .steamInstallationFailed(error.localizedDescription)
            state = .steamInstallerVerified
            log("InstallSteam error: \(error.localizedDescription)")
        }
    }

    /// Basic environment for Wine operations (no dependency layout needed).
    private func buildBasicEnvironment() -> [String: String] {
        guard let prefix = prefixLayout?.root else { return [:] }
        return [
            "WINEPREFIX": prefix.path,
            "WINEARCH": "win64",
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
        ]
    }

    /// Reconcile Steam install lifecycle from disk state.
    /// Call after prefix is configured and on app launch.
    func reconcileSteamInstallLifecycle() {
        guard let prefix = prefixLayout?.root else { return }
        let fm = FileManager.default

        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let steamExe = steamDir.appendingPathComponent("steam.exe")
        let holdFile = steamDir.appendingPathComponent("steam.exe.macsteam-install-hold")

        if fm.fileExists(atPath: holdFile.path) {
            // Steam is quarantined — interrupted installation
            steamInstallLifecycle = .interrupted
            log("Steam installation interrupted (hold file detected)")
        } else if fm.fileExists(atPath: steamExe.path) {
            let attrs = try? fm.attributesOfItem(atPath: steamExe.path)
            let size = attrs?[.size] as? UInt64 ?? 0
            if size > 0 {
                steamInstallLifecycle = .verifiedComplete
                log("Steam installation verified complete (steam.exe found)")
            }
        } else {
            steamInstallLifecycle = .absent
            log("Steam not installed")
        }
    }

    /// Verify an existing Steam installation and mark it as complete.
    /// Called when user clicks "Verify Completed Installation".
    func verifySteamInstallation() {
        guard let prefix = prefixLayout?.root else { return }
        let fm = FileManager.default

        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let steamExe = steamDir.appendingPathComponent("steam.exe")
        let holdFile = steamDir.appendingPathComponent("steam.exe.macsteam-install-hold")

        // If held, restore it
        if fm.fileExists(atPath: holdFile.path) {
            try? fm.moveItem(at: holdFile, to: steamExe)
            log("Restored steam.exe from quarantine")
        }

        // Verify
        guard fm.fileExists(atPath: steamExe.path) else {
            error = .steamInstallationFailed("steam.exe not found after restoration")
            return
        }
        let attrs = try? fm.attributesOfItem(atPath: steamExe.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        guard size > 0 else {
            error = .steamInstallationFailed("steam.exe is empty")
            return
        }

        steamInstallLifecycle = .verifiedComplete
        state = .steamReady
        log("Steam installation verified complete by user")
    }

    /// Re-check Steam installation status (polling).
    func recheckSteam() async {
        let inspection = inspectSteamInstallation()
        self.steamInspection = inspection
        state = inspection.steamInstalled ? .steamReady : .steamInstallationPending
    }

    /// Step 5: Re-check CloverPit installation.
    func recheckCloverPit() async {
        // NX Dispatch §12: Clear stale state before each re-check
        self.cloverPitInspection = nil
        log("Step 5: Checking CloverPit installation…")
        guard let runtime = activeRuntime else {
            self.cloverPitInspection = .notReady(recipeID: recipe.id)
            state = .cloverPitNotInstalled
            log("ERROR: No active runtime for CloverPit check")
            return
        }

        // NX Dispatch §4: Inspection must use the same canonical prefix as everything else
        guard let prefix = prefixLayout else {
            self.cloverPitInspection = .notReady(recipeID: recipe.id)
            state = .cloverPitNotInstalled
            log("ERROR: No canonical prefix layout resolved")
            return
        }

        log("Running Steam detector with validated canonical prefix")
        let inspection = await steamDetector.inspect(recipe: recipe, runtime: runtime, prefix: prefix)
        self.cloverPitInspection = inspection
        state = inspection.isReady ? .cloverPitReady : .cloverPitNotInstalled

        log("Steam present: \(inspection.steamPresent)")
        log("Windows Steam: \(inspection.isWindowsSteam)")
        log("Manifest present: \(inspection.manifestPresent)")
        log("Install dir resolved: \(inspection.installDirectoryResolved)")
        log("Executable present: \(inspection.executablePresent)")
        log("Install state: \(inspection.installState.rawValue)")
        log("Canonical install present: \(inspection.canonicalInstallPresent)")
        log("Download payload present: \(inspection.downloadPayloadPresent)")
        log("isReady: \(inspection.isReady)")

        if !inspection.isReady {
            // Check if steam is at least present
            let steamCheck = inspectSteamInstallation()
            if !steamCheck.steamInstalled {
                state = .steamReady // user should launch Steam manually
                log("Steam also not detected — reverting to Steam ready state")
            }
        }
    }

    /// Step 6b: Launch or Show Windows Steam UI (no game args).
    ///
    /// Idempotent: if Steam is already running, just shows the window.
    /// If Steam is stopped, launches a new process.
    func launchWindowsSteam() async {
        guard !isLaunchingSteam else {
            log("Steam launch already in progress, ignoring duplicate request")
            return
        }

        // Lifecycle guard: incomplete installation blocks launch
        guard steamInstallLifecycle == .verifiedComplete else {
            if steamInstallLifecycle == .installing || steamInstallLifecycle == .interrupted {
                log("Steam installation incomplete (\(steamInstallLifecycle)), blocking launch")
                state = .steamInstallationPending
                error = .steamInstallationFailed(
                    "Steam installation is incomplete. Resume or verify installation first."
                )
            }
            return
        }

        isLaunchingSteam = true
        defer { isLaunchingSteam = false }
        error = nil

        // Reconcile current process state
        await reconcileSteamClient()

        // If already visible or hidden, just activate
        switch steamClientState {
        case .runningVisible, .runningHidden:
            log("Steam already running — window activation pending SteamWindowInventory")
            return
        case .launching, .stopping:
            log("Steam is launching/stopping, ignoring launch request")
            return
        case .stopped, .stale, .recoveryRequired:
            break // proceed to launch
        }

        state = .launching

        guard let runtime = activeRuntime,
              let runtimeURL = runtimeURL,
              let runtimeControl = runtime as? WineRuntimeControl
        else {
            error = .launchFailed("No runtime selected or runtime lacks WineRuntimeControl")
            state = .steamReady
            return
        }

        // Resolve wine executable using WineExecutableLayout
        let layout = WineExecutableLayout.detect(from: runtimeURL)
        let wineURL = layout.wine

        let steamExe1 = prefixLayout?.root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe") ?? URL(fileURLWithPath: "/dev/null")
        let steamExe2 = prefixLayout?.root.appendingPathComponent("drive_c/Program Files/Steam/steam.exe") ?? URL(fileURLWithPath: "/dev/null")
        let steamExe = FileManager.default.fileExists(atPath: steamExe1.path) ? steamExe1 : steamExe2

        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            error = .launchFailed("Steam not installed in prefix")
            state = .steamInstallerRequired
            return
        }

        log("Launching Windows Steam (idempotent)…")
        steamClientState = .launching

        do {
            // Build safe environment with DYLD_LIBRARY_PATH etc.
            let environment = buildWineEnvironment()
            let prefixURL = prefixLayout?.root ?? URL(fileURLWithPath: "/")

            let plan = makeSteamSessionPlan(
                wineURL: wineURL,
                steamURL: steamExe,
                prefixURL: prefixURL,
                environment: environment,
                renderArguments: steamUIRenderProfile.launchArguments
            )

            let _ = try await sessionSupervisor.launch(
                plan: plan,
                runtimeControl: runtimeControl,
                prefixRoot: prefixURL,
                recipeID: "steam-setup",
                runtimeID: runtimeSourceType ?? "unknown",
                purpose: .steamSetup
            )

            log("Windows Steam session started: purpose=steamSetup, profile=\(steamUIRenderProfile.rawValue)")
            // U1R18 R1: visibility is MEASURED from the WindowServer via the
            // supervisor's observer, never guessed. Right after launch the
            // supervisor reports runningUnknown; the observer drives it to
            // runningVisible/runningHidden. Mark as launching here.
            steamClientState = .launching
            state = .steamReady
        } catch {
            self.error = .launchFailed(error.localizedDescription)
            steamClientState = .stopped
            state = .steamReady
        }
    }

    /// Build safe Wine environment using WineLaunchEnvironmentBuilder.
    private func buildWineEnvironment() -> [String: String] {
        guard let runtimeURL = runtimeURL,
              let prefix = prefixLayout?.root else {
            return buildBasicEnvironment()
        }

        // Try RuntimeDependencyLayout first for DYLD_LIBRARY_PATH
        if let depLayout = RuntimeDependencyLayout(runtimePath: runtimeURL.path) {
            let libDir = depLayout.libDirectory()
            let fm = FileManager.default
            if fm.fileExists(atPath: libDir.path) {
                // Builder may fail due to PathBoundary; try direct env construction
                var env = buildBasicEnvironment()
                env["DYLD_LIBRARY_PATH"] = libDir.path
                let fcDir = depLayout.fontconfigDirectory()
                if fm.fileExists(atPath: fcDir.path) {
                    env["FONTCONFIG_PATH"] = fcDir.path
                }
                return env
            }
        }

        log("Warning: RuntimeDependencyLayout unavailable, using basic environment")
        return buildBasicEnvironment()
    }

    /// Reconcile steamClientState with actual process state.
    func reconcileSteamClient() async {
        // U1R18 R1: when a supervised session is active, visibility comes from
        // the WindowServer observer (sessionSupervisor.state), NOT from guessing
        // or from process table heuristics.
        if sessionSupervisor.activeSession != nil {
            steamClientState = SteamClientState(sessionState: sessionSupervisor.state)
            return
        }

        guard let runtimeURL = runtimeURL,
              let prefix = prefixLayout?.root else {
            steamClientState = .stopped
            return
        }

        let layout = WineExecutableLayout.detect(from: runtimeURL)
        let tasklistURL = layout.wine

        // Check steam.exe presence via Wine's tasklist
        do {
            let environment = buildWineEnvironment()
            let result = try await processRunner.run(
                executable: tasklistURL,
                arguments: ["tasklist", "/FO", "CSV"],
                environment: environment,
                workingDirectory: prefix,
                mode: .waitForExit
            )
            let output = result.stdout
            let hasSteam = output.contains("steam.exe")
            let hasHelper = output.contains("steamwebhelper.exe")

            if hasSteam {
                steamClientState = .runningHidden // assume hidden until proven visible
            } else if hasHelper {
                steamClientState = .stale
            } else {
                steamClientState = .stopped
            }
        } catch {
            log("Reconcile failed: \(error.localizedDescription)")
            steamClientState = .stopped
        }
    }

    /// Step 6: Launch CloverPit through Windows Steam via GameSessionSupervisor.
    func launchCloverPit() async {
        state = .launching
        error = nil
        launchPhase = nil

        guard let runtime = activeRuntime,
              let runtimeURL = runtimeURL,
              let runtimeControl = runtime as? WineRuntimeControl
        else {
            error = .launchFailed("No runtime selected or runtime lacks WineRuntimeControl")
            state = .cloverPitReady
            return
        }

        let wineURL: URL
        if runtime is SystemWineRuntime {
            wineURL = runtimeURL.appendingPathComponent("wine")
        } else {
            wineURL = runtimeURL.appendingPathComponent("bin/wine")
        }

        let steamExe1 = prefixLayout?.root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe") ?? URL(fileURLWithPath: "/dev/null")
        let steamExe2 = prefixLayout?.root.appendingPathComponent("drive_c/Program Files/Steam/steam.exe") ?? URL(fileURLWithPath: "/dev/null")
        let steamExe = FileManager.default.fileExists(atPath: steamExe1.path) ? steamExe1 : steamExe2

        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            error = .launchFailed("Steam not installed in prefix")
            state = .steamInstallerRequired
            return
        }

        do {
            let prefixURL = prefixLayout?.root ?? URL(fileURLWithPath: "/")
            let environment = buildWineEnvironment()

            let plan = makeCloverPitSessionPlan(
                wineURL: wineURL,
                steamURL: steamExe,
                prefixURL: prefixURL,
                environment: environment,
                renderArguments: steamUIRenderProfile.launchArguments
            )

            let session = try await sessionSupervisor.launch(
                plan: plan,
                runtimeControl: runtimeControl,
                prefixRoot: prefixURL,
                recipeID: "cloverpit",
                runtimeID: runtimeSourceType ?? "unknown",
                purpose: .game
            )

            launchPhase = .processObserved
            state = .processObserved
            // activeSession is exposed via sessionSupervisor.activeSession
        } catch {
            self.error = .launchFailed(error.localizedDescription)
            state = .cloverPitReady
        }
    }

    /// User confirmed seeing CloverPit window.
    func confirmWindow() {
        launchPhase = .windowConfirmed
    }

    /// User confirmed seeing main menu.
    func confirmMainMenu() {
        launchPhase = .mainMenuConfirmed
    }

    // MARK: - Cleanup orchestrator

    private enum UltimateCleanupScope {
        case activeSession
        case all
    }

    /// Perform lifecycle cleanup across installer, session, and prefix processes.
    /// Returns "clean" on success, or a semicolon-separated error summary.
    private func performLifecycleCleanup(scope: UltimateCleanupScope) async -> String {
        // Snapshot authority BEFORE any mutation
        let installerSnapshotAtStart = await lifecycleInstaller.snapshot()
        let sessionAuthorityAtStart = sessionSupervisor.activeSession != nil
            || sessionSupervisor.needsRecovery
            || sessionSupervisor.isStopping
        let installerAuthorityAtStart = installerSnapshotAtStart != nil
        let hadCleanupAuthorityAtStart = sessionAuthorityAtStart || installerAuthorityAtStart

        var failures: [String] = []

        // Stage 1: Installer cleanup
        do {
            try await lifecycleInstaller.stopAndClean()
        } catch {
            logCleanupFailure(stage: "Installer", error: error)
            failures.append("Installer cleanup failed")
        }

        // Stage 2: Session stop
        if scope == .all || sessionSupervisor.activeSession != nil {
            do {
                try await sessionSupervisor.stop()
            } catch {
                logCleanupFailure(stage: "Session", error: error)
                failures.append("Session cleanup failed")
            }
        }

        // Stage 3: Prefix cleanup (best-effort, after all other stages)
        if let activeRuntimeURL = runtimeURL, let prefixURL = prefixLayout?.root {
            let layout = WineExecutableLayout.detect(from: activeRuntimeURL)
            do {
                try await lifecycleInstaller.stopKnownPrefixProcesses(
                    wineExecutable: layout.wine,
                    wineserverURL: layout.wineserver,
                    prefixURL: prefixURL,
                    runtimeURL: activeRuntimeURL
                )
            } catch {
                logCleanupFailure(stage: "Prefix", error: error)
                failures.append("Prefix cleanup failed")
            }
        } else if hadCleanupAuthorityAtStart {
            failures.append("Prefix cleanup context unavailable")
        }

        return failures.isEmpty ? "clean" : failures.joined(separator: "; ")
    }

    /// Stop the active game session.
    /// Returns true if stopped or no session; false if stop failed.
    @discardableResult
    func stopSession() async -> Bool {
        log("stopSession via lifecycle cleanup")
        let result = await performLifecycleCleanup(scope: .activeSession)
        let clean = result == "clean"
        if clean {
            steamClientState = .stopped
            isLaunchingSteam = false
        } else {
            steamClientState = .recoveryRequired("cleanup incomplete")
        }
        return clean
    }

    /// Whether a Steam setup session is active.
    var hasActiveSteamSetupSession: Bool {
        sessionSupervisor.activeSession?.purpose == .steamSetup
        && sessionSupervisor.isRunning
    }

    /// Single navigation entry point for all UI pages.
    func send(_ intent: InstallerNavigationIntent) async {
        // coordinator.currentPage is the single authority — the reducer
        // adopts it before every intent so the two can never diverge.
        await navigationReducer.adopt(page: currentPage)

        let result: InstallerNavigationResult

        switch intent {
        case .next:
            // Next with an active operation requires real cleanup first
            // (fail-closed: never advance past a running session).
            if hasActiveOperation {
                let outcome = await stopAllForApplicationTermination()
                if outcome != .clean {
                    currentPage = currentPage // stay
                    lastNavigationResult = InstallerNavigationResult(
                        accepted: false,
                        newPage: nil,
                        blocker: InstallerNavigationBlocker(
                            code: "cleanup_required",
                            message: "Cleanup incomplete: \(outcome)"
                        )
                    )
                    return
                }
            }

            // Update reducer's state from actual coordinator state
            let completion = computePageCompletion()
            for (page, complete) in completion {
                await navigationReducer.setPageComplete(page, complete)
            }
            await navigationReducer.setActiveOperation(hasActiveOperation)
            await navigationReducer.setCleanupRequired(isCleanupRequired)
            result = await navigationReducer.send(intent: intent)
            if result.accepted, let newPage = result.newPage {
                currentPage = newPage
            }

        case .back:
            // Back with active operation requires real cleanup
            if hasActiveOperation {
                let outcome = await stopAllForApplicationTermination()
                if outcome != .clean {
                    currentPage = currentPage // stay
                    lastNavigationResult = InstallerNavigationResult(
                        accepted: false,
                        newPage: nil,
                        blocker: InstallerNavigationBlocker(
                            code: "cleanup_required",
                            message: "Cleanup incomplete: \(outcome)"
                        )
                    )
                    return
                }
            }

            await navigationReducer.setCleanupRequired(isCleanupRequired)
            result = await navigationReducer.send(intent: intent)
            if result.accepted, let newPage = result.newPage {
                currentPage = newPage
            }

        case .stopAndClean:
            let outcome = await stopAllForApplicationTermination()
            guard outcome == .clean else {
                lastNavigationResult = InstallerNavigationResult(
                    accepted: false,
                    newPage: nil,
                    blocker: InstallerNavigationBlocker(
                        code: "cleanup_required",
                        message: "Cleanup incomplete: \(outcome)"
                    )
                )
                return
            }
            result = InstallerNavigationResult(accepted: true, newPage: currentPage, blocker: nil)
        }

        lastNavigationResult = result
    }

    var hasActiveOperation: Bool {
        sessionSupervisorIsRunning
    }

    private var isCleanupRequired: Bool {
        if case .recoveryRequired = steamClientState { return true }
        return false
    }

    func computePageCompletion() -> [InstallerPage: Bool] {
        var completion: [InstallerPage: Bool] = [:]
        completion[.runtime] = runtimeURL != nil && runtimeInspection?.isUsable == true
        // Environment completes only with verification evidence bound to the
        // CURRENT canonical prefix root (layout + isValid + canonical URL match).
        completion[.environment] = canonicalPrefixEvidenceValid
        completion[.steamInstaller] = selectedInstaller != nil || steamInstallLifecycle == .verifiedComplete
        completion[.steamClient] = steamInstallLifecycle == .verifiedComplete
        completion[.cloverPit] = cloverPitInspection?.isReady == true
        completion[.diagnostics] = true
        return completion
    }

    /// Stop Steam setup session for app termination.
    /// Returns true if stopped or no session; false if stop failed.
    func stopSteamSetupForTermination() async -> Bool {
        log("stopSteamSetupForTermination via lifecycle cleanup")
        let result = await performLifecycleCleanup(scope: .all)
        return result == "clean"
    }

    /// Stop all processes for application termination.
    /// Stops: installer, game session, known prefix processes, wineserver.
    func stopAllForApplicationTermination() async -> CleanupResult {
        log("stopAllForApplicationTermination via lifecycle cleanup")
        let result = await performLifecycleCleanup(scope: .all)
        if result == "clean" {
            return .clean
        }
        return .incomplete(result)
    }

    /// Stop steam setup session if active (for back/next/close transitions).
    /// Returns true if stopped or no session; false if stop failed (caller should stay on screen).
    func stopSteamSetupSessionIfNeeded() async -> Bool {
        log("stopSteamSetupSessionIfNeeded via lifecycle cleanup")
        let result = await performLifecycleCleanup(scope: .activeSession)
        return result == "clean"
    }

    // MARK: - Session supervisor proxy

    /// Current session state from the supervisor.
    var sessionSupervisorState: GameSessionState {
        sessionSupervisor.state
    }

    /// Whether a session is currently running.
    var sessionSupervisorIsRunning: Bool {
        sessionSupervisor.isRunning
    }

    /// Whether the supervised session's WindowServer observer is active.
    /// The production supervisor is a concrete `GameSessionSupervisor`;
    /// injected fakes report false.
    var sessionSupervisorIsWindowMonitoring: Bool {
        (sessionSupervisor as? GameSessionSupervisor)?.isWindowMonitoring ?? false
    }

    /// Whether a stop is in progress.
    var sessionSupervisorIsStopping: Bool {
        sessionSupervisor.isStopping
    }

    /// Whether recovery is needed.
    var sessionSupervisorNeedsRecovery: Bool {
        sessionSupervisor.needsRecovery
    }

    // MARK: - Diagnostics / Receipt

    /// Build a receipt dictionary for the PR body / local log.
    func buildReceipt() -> [String: Any] {
        [
            "runtime": [
                "type": runtimeSourceType ?? "unknown",
                "version": runtimeExactVersion ?? "unknown",
                "architecture": runtimeArchitecture ?? "unknown",
            ] as [String: String],
            "prefix": [
                "created": prefixInspection != nil,
                "driveCExists": prefixInspection?.driveCExists ?? false,
            ],
            "steam": [
                "installerSelected": selectedInstaller != nil,
                "installed": steamInspection?.steamInstalled ?? false,
            ],
            "cloverpit": [
                "manifestPresent": cloverPitInspection?.manifestPresent ?? false,
                "executablePresent": cloverPitInspection?.executablePresent ?? false,
                "isReady": cloverPitInspection?.isReady ?? false,
            ],
            "launch": [
                "phase": launchPhase?.rawValue ?? "none",
            ],
        ]
    }

    /// Generate a redacted, size-bounded diagnostic bundle from live coordinator state.
    func generateDiagnosticBundle() async -> DiagnosticBundle {
        let installerOp = await lifecycleInstaller.snapshot()
        let sig = prefixLayout?.signature()
        let evidence = steamInstallEvidence
        let session = activeSession
        let processCensus = await sessionSupervisor.processCensus()

        return DiagnosticBundle(
            schemaVersion: DiagnosticBundle.currentSchemaVersion,
            generatedAt: Date(),
            installerLifecycle: InstallerLifecycleDiagnostic(
                phase: installerOp?.phase.rawValue ?? "none",
                isActive: installerOp?.phase.isActive ?? false,
                isTerminal: installerOp?.phase.isTerminal ?? false,
                installerID: installerID,
                hasLastError: installerOp?.lastError != nil
            ),
            runtime: RuntimeDiagnostic(
                sourceType: runtimeSourceType,
                exactVersion: runtimeExactVersion,
                architecture: runtimeArchitecture,
                isUsable: runtimeInspection?.isUsable,
                capabilities: runtimeInspection.map { inspection in
                    var caps: [String] = []
                    let c = inspection.capabilities
                    if c.contains(.windowsProcess) { caps.append("windowsProcess") }
                    if c.contains(.steamClient) { caps.append("steamClient") }
                    if c.contains(.isolatedPrefix) { caps.append("isolatedPrefix") }
                    if c.contains(.wined3d) { caps.append("wined3d") }
                    if c.contains(.wow64) { caps.append("wow64") }
                    return caps
                } ?? [],
                failureCodes: (runtimeInspection?.failures ?? []).map { $0.code.rawValue },
                realLoadHealthy: realLoadHealthy,
                realLoadStatus: realLoadResult?.status.rawValue
            ),
            prefixAcquisition: PrefixAcquisitionDiagnostic(
                source: lastAcquisitionLog?.source?.rawValue,
                canonicalPrefixValid: lastAcquisitionLog?.canonicalPrefixValid ?? false,
                canonicalSteamPresent: lastAcquisitionLog?.canonicalSteamPresent ?? false,
                adoptionCandidateCount: lastAcquisitionLog?.adoptionCandidateCount ?? 0,
                adoptionResult: lastAcquisitionLog?.adoptionResult.rawValue,
                signatureValid: sig?.isValid ?? false,
                signatureDriveC: sig?.driveCDirectory ?? false,
                signatureDosdevices: sig?.dosdevicesDirectory ?? false,
                signatureSymlinkResolves: sig?.dosdevicesCResolvesToDriveC ?? false,
                signatureSteamExe: sig?.steamExePresent ?? false,
                evidenceBound: canonicalPrefixEvidenceValid
            ),
            steamPayload: SteamPayloadDiagnostic(
                lifecycle: steamInstallLifecycle.rawValue,
                exePresent: evidence.steamExePresent,
                exeNonEmpty: evidence.steamExeNonEmpty,
                installerRunning: evidence.installerRunning,
                steamInstalled: steamInspection?.steamInstalled ?? false,
                installState: cloverPitInspection?.installState.rawValue,
                canLaunch: evidence.canLaunchSteam
            ),
            supervisedSession: SupervisedSessionDiagnostic(
                state: sessionStateLabel(sessionSupervisorState),
                isRunning: sessionSupervisorIsRunning,
                isStopping: sessionSupervisorIsStopping,
                needsRecovery: sessionSupervisorNeedsRecovery,
                purpose: session?.purpose.rawValue,
                recipeID: session?.recipeID,
                sessionAgeSeconds: session.map { Date().timeIntervalSince($0.startedAt) }
            ),
            wineProcessCensus: WineProcessCensusDiagnostic(census: processCensus),
            wineserver: WineserverDiagnostic(
                state: "unknown"
            ),
            windowInventory: WindowInventoryDiagnostic(
                windowCount: 0,
                visibility: "unknown"
            ),
            boundedOutput: BoundedOutputDiagnostic(
                lineCount: installerLog.components(separatedBy: .newlines).filter { !$0.isEmpty }.count,
                truncated: installerLog.components(separatedBy: .newlines).filter { !$0.isEmpty }.count > DiagnosticSizeLimits.maxOutputLines,
                lines: DiagnosticRedactor.redactLines(installerLog)
            ),
            failureClassification: FailureClassificationDiagnostic(
                errorCase: error.map { Self.errorCaseLabel($0) },
                hasError: error != nil,
                setupState: state.displayName
            ),
            cleanup: CleanupDiagnostic(
                cleanupProof: "notRun",
                hostProcessProof: "notProven",
                windowVisibility: "unknown"
            )
        )
    }

    // MARK: - Private

    private func sessionStateLabel(_ s: GameSessionState) -> String {
        switch s {
        case .idle: return "idle"
        case .launching: return "launching"
        case .runningUnknown: return "runningUnknown"
        case .runningVisible: return "runningVisible"
        case .runningHidden: return "runningHidden"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .recoveryRequired: return "recoveryRequired"
        case .failed: return "failed"
        }
    }

    nonisolated private static func errorCaseLabel(_ error: UltimateSetupError) -> String {
        switch error {
        case .runtimeNotFound: return "runtimeNotFound"
        case .runtimeInspectionFailed: return "runtimeInspectionFailed"
        case .prefixCreationFailed: return "prefixCreationFailed"
        case .installerSelectionFailed: return "installerSelectionFailed"
        case .installerVerificationFailed: return "installerVerificationFailed"
        case .steamInstallationFailed: return "steamInstallationFailed"
        case .cloverPitNotDetected: return "cloverPitNotDetected"
        case .launchFailed: return "launchFailed"
        case .ownershipRequired: return "ownershipRequired"
        case .processTimeout: return "processTimeout"
        case .processCancelled: return "processCancelled"
        case .ambiguousAdoption: return "ambiguousAdoption"
        }
    }

    /// Single production authority: generate, sanitize, and export a diagnostic
    /// bundle to the trusted MacSteam diagnostics root.
    func exportDiagnosticBundle(filename: String = "diagnostic-bundle.json") async throws -> URL {
        let bundle = await generateDiagnosticBundle()
        let target = try DiagnosticTrustedRoot.validatedTarget(filename: filename)
        try DiagnosticBundleWriter.write(bundle, to: target)
        log("Diagnostic bundle exported (schema v\(bundle.schemaVersion))")
        return target
    }

    private func inspectSteamInstallation() -> SteamInstallationInspection {
        let fm = FileManager.default
        let candidates = [
            prefixLayout?.root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe") ?? URL(fileURLWithPath: "/dev/null"),
            prefixLayout?.root.appendingPathComponent("drive_c/Program Files/Steam/steam.exe") ?? URL(fileURLWithPath: "/dev/null"),
        ]
        for candidate in candidates {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            // Get version from steam.exe if possible
            return SteamInstallationInspection(
                steamInstalled: true,
                steamExePath: candidate.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"),
                steamVersion: nil
            )
        }
        return .notFound
    }

    private func computeSHA256(url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespaces)
        } catch {
            return nil
        }
    }
}
