// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MacsTeamControlPlane
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

/// U1R18-R13-ACCEPTANCE3-FIX1: deterministic, total reconciliation of Steam
/// install truth for the CURRENT canonical prefix payload. This is the single
/// coordinator-owned projection — no path may claim Steam-ready except through
/// it. The projection is a pure function of the current prefix on disk:
///
/// - interrupted-hold file present → `.interrupted`, not ready
/// - regular non-empty steam.exe    → `.verifiedComplete`, ready
/// - zero-byte or invalid steam.exe → `.absent`, not ready
/// - missing steam.exe              → `.absent`, not ready
struct SteamReconciliation: Sendable, Equatable {
    let lifecycle: SteamInstallLifecycle
    /// Whether a regular, non-empty steam.exe is present in the canonical prefix.
    let steamInstalled: Bool
    /// Whether Steam is currently ready (lifecycle `.verifiedComplete`).
    let ready: Bool
    /// Whether the interrupted-install hold file is present in the prefix.
    let interruptedHoldPresent: Bool

    /// Setup state the projection raises for the operator. Steam-ready only
    /// ever maps from a reconciled `.verifiedComplete` lifecycle.
    var projectedSetupState: UltimateSetupState {
        if lifecycle == .verifiedComplete { return .steamReady }
        if interruptedHoldPresent { return .steamInstallerVerified }
        return .steamInstallerRequired
    }
}

@MainActor
@Observable
final class UltimateSetupCoordinator {
    // MARK: - Published state

    /// U1R18-R13-FIX1 §3.3: developer-local build identity (embedded SHA or a
    /// safe `swift run` fallback). Read-only; never a git lookup at runtime.
    let buildIdentity: BuildIdentity

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

    /// U1R18-R11: fail-closed local runtime acceptance (single mutation owner).
    /// Read-only surface below; the authority itself is the sole mutator.
    private var localAcceptanceAuthority: LocalRuntimeAcceptanceAuthority?

    /// Task that feeds reduced machine snapshots to the acceptance authority.
    private var localAcceptanceMonitorTask: Task<Void, Never>?

    /// U1R18-R12: durable accepted-only store the authority persists into
    /// strictly before it may enter the accepted state. Injectable for tests;
    /// production roots at the MacSteam Application Support namespace.
    private let localAcceptanceReceiptStore: LocalAcceptanceReceiptStore

    var acceptanceState: LocalAcceptanceState { localAcceptanceAuthority?.state ?? .notStarted }
    var acceptanceBlocker: LocalAcceptanceBlocker? { localAcceptanceAuthority?.blocker }
    var acceptanceStabilitySeconds: Int { localAcceptanceAuthority?.visibilityStableSeconds ?? 0 }
    var acceptanceStable: Bool {
        acceptanceState == .awaitingOperatorConfirmation || acceptanceState == .accepted
    }
    var acceptanceMenuConfirmed: Bool { localAcceptanceAuthority?.menuConfirmed ?? false }
    var acceptanceInputConfirmed: Bool { localAcceptanceAuthority?.inputConfirmed ?? false }
    var acceptanceReceiptJSON: String {
        localAcceptanceAuthority?.currentReceipt.deterministicJSONString ?? "{}"
    }

    /// U1R18-R12: bounded historical evidence loaded from the durable store.
    /// A loaded receipt is historical evidence only — it is never used to
    /// promote the current acceptance state nor to satisfy the current
    /// transaction.
    var hasSavedLocalAcceptanceReceipt: Bool {
        savedLocalStore != nil
    }

    /// Bounded status string of the saved receipt, or nil when none/invalid.
    /// Never leaks raw paths, PIDs, identifiers or error text.
    var savedLocalAcceptanceReceiptStatus: String? {
        savedLocalStore?.status.state.rawValue
    }

    /// The loaded receipt (bounded evidence), or nil when absent/invalid.
    /// Loading is historical-evidence only; it never promotes the current
    /// acceptance state nor satisfies the current transaction.
    var savedLocalStore: LocalAcceptanceReceipt? {
        switch localAcceptanceReceiptStore.loadAccepted() {
        case .loaded(let receipt): return receipt
        default: return nil
        }
    }

    /// U1R18-R11-FIX1: presentation model consumed by the CloverPit acceptance
    /// UI. Derived from the authority's read-only surface and never mutated
    /// here.
    var acceptancePresentation: LocalAcceptancePresentation {
        let state = acceptanceState
        let blocked = state == .blocked
        let invalidated = state == .invalidated
        let accepted = state == .accepted

        let inOperatorPhase = state == .awaitingOperatorConfirmation
        let canConfirmMainMenu = inOperatorPhase && !acceptanceMenuConfirmed
        let canConfirmInputResponse = inOperatorPhase
            && acceptanceMenuConfirmed
            && !acceptanceInputConfirmed
        let canComplete = inOperatorPhase && acceptanceMenuConfirmed && acceptanceInputConfirmed

        let title: String
        let body: String
        if accepted {
            title = "Runtime acceptance complete"
            body = "Cleanup complete, receipt available."
        } else if blocked {
            title = "Runtime acceptance blocked"
            body = acceptanceBlocker.map { String(describing: $0) } ?? "Unknown blocker."
        } else if invalidated {
            title = "Runtime acceptance cannot complete"
            body = "The session ended before acceptance completed."
        } else if state == .awaitingStableVisibility {
            title = "Confirming CloverPit window"
            body = "Keep the window visible \(acceptanceStabilitySeconds)/30 seconds."
        } else if inOperatorPhase {
            title = "Confirm the CloverPit session"
            body = "Confirm the main menu, then the input response."
        } else {
            title = "Local runtime acceptance"
            body = "Preparing acceptance."
        }

        return LocalAcceptancePresentation(
            isVisible: state != .notStarted && state != .inProgress,
            canConfirmMainMenu: canConfirmMainMenu,
            canConfirmInputResponse: canConfirmInputResponse,
            canComplete: canComplete,
            title: title,
            body: body
        )
    }

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

    /// Discovered runtime candidates snapshot (bounded, for `runtime list`).
    /// Refreshed by `inspectSystem()` / `selectRuntime(_:)` / `selectRuntime(id:)`;
    /// never recomputed on the 250ms mirror tick.
    private(set) var runtimeCandidatesSnapshot: [ControlPlaneRuntimeCandidate] = []

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

    /// U1R18-R13-FIX1-FIX5: the real-load probe EXECUTION boundary used by the
    /// production validation orchestrator's full branch.
    ///
    /// Production default is exactly the previous behaviour: build a fresh
    /// ``WineRealLoadProbe`` and run it against the candidate. Tests inject a
    /// deterministic executor whose invocations can be counted, so a FIX5 test
    /// observes how many times the full branch really executed the probe —
    /// without any test deciding whether the orchestrator takes full/fast.
    var realLoadProbeExecution: @MainActor (URL, URL, URL) async -> WineRealLoadResult = {
        runtimeURL, wineURL, scratchPrefixRoot in
        await WineRealLoadProbe().probe(
            runtimeURL: runtimeURL,
            wineURL: wineURL,
            scratchPrefixRoot: scratchPrefixRoot
        )
    }

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

    /// Control-plane navigation tracking: the intent and source page of the
    /// last `send(_:)`. Captured at the top of every navigation dispatch so the
    /// terminal transition record never invents a from/action.
    @MainActor private(set) var lastNavigationIntent: InstallerNavigationIntent?
    @MainActor private(set) var lastNavigationFromPage: InstallerPage?

    private var activeRuntime: (any CompatibilityRuntime)?
    var runtimeURL: URL?

    /// Canonical prefix layout resolved by PrefixManager (single source of truth).
    var prefixLayout: PrefixLayout? {
        didSet {
            if oldValue?.root != prefixLayout?.root {
                prefixInspection = nil
                // U1R18-R13-ACCEPTANCE3-FIX1: a different canonical prefix
                // invalidates stale Steam truth. Never reuse the previous
                // prefix's inspection or lifecycle projection.
                steamInspection = nil
                steamInstallLifecycle = .absent
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
        // FIX C: a different canonical prefix clears stale prefix evidence.
        if milestonePrefixIdentity != nil && milestonePrefixIdentity != layout.root.path {
            launchAuthority.clearMilestone(.canonicalPrefixBound)
            launchCache.invalidate()
        }
        self.prefixLayout = layout
        self.milestonePrefixIdentity = layout.root.path
        let inspector = prefixInspectorProvider()
        let inspection = inspector.inspect(url: layout.root)
        self.prefixInspection = inspection
        // U1R18-R13-FIX1-FIX1 §3.2: canonical current-prefix evidence is bound.
        if canonicalPrefixEvidenceValid {
            launchAuthority.earn(.canonicalPrefixBound)
        }
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

    /// U1R18-R13-FIX1-FIX1 §3: single production launch telemetry authority.
    ///
    /// The wine progress meter is derived from completed production milestones
    /// (never a fake timer). Steam timing is measured with a monotonic clock and
    /// the ETA comes from a bounded median history. Arbitrary call sites cannot
    /// freely assign stage values — only the methods here advance the authority.
    private(set) var launchAuthority = LaunchTransitionAuthority()

    var launchPipelineStage: LaunchPipelineStage { launchAuthority.stage }
    var wineMilestones: WineMilestones { launchAuthority.wineMilestones }
    var launchTiming: LaunchTiming { launchAuthority.timing }

    /// Production owner of the safe fast-path cache (§7).
    private(set) var launchCache = LaunchValidationCache()

    /// Bounded material file-identity provider (injectable for tests).
    private let fileIdentityProvider: any LaunchFileIdentityProviding

    private var timingStore = LaunchTimingStore()

    /// Launcher monotonic clock (injectable for tests).
    private let launchClock: any LaunchClock

    /// Monotonic stopwatch start for the pending Steam-ready boundary.
    private var steamReadyStopwatch: LaunchStopwatch?

    /// Bounded attempt generation token (FIX H): a stale Steam-ready observer
    /// must never complete a later attempt. Incremented on each new attempt.
    private var attemptGeneration: UInt64 = 0

    /// The validation path of the most recent attempt, frozen at the validation
    /// decision BEFORE cache publication (FIX F).
    private(set) var lastValidationPath: LaunchValidationPath?

    /// Launch path label for the last-attempt breakdown (truthful, not a warm
    /// Steam process-reuse claim).
    private(set) var lastLaunchPath: String?

    /// The exact fingerprint used by the current attempt's validation.
    var attemptFingerprint: LaunchValidationFingerprint?

    /// Whether the current runtime capability gate actually passed (FIX C).
    private var runtimeCapabilityValidatedFlag = false

    /// Identity the current Wine evidence milestones were earned for (FIX C).
    private var milestoneRuntimeIdentity: String?
    private var milestonePrefixIdentity: String?

    /// Re-seed Wine evidence from CURRENT identity-bound evidence. If the
    /// runtime or prefix identity changed since the milestones were earned,
    /// stale evidence is cleared and re-earned from current evidence, so a new
    /// attempt never carries stale evidence across an identity change.
    private func reconcileMilestoneEvidence() {
        let rt = runtimeURL?.path
        let px = prefixLayout?.root.path
        if milestoneRuntimeIdentity != rt || milestonePrefixIdentity != px {
            for k in [WineMilestoneKey.runtimeResolved, .runtimeCapabilityValidated,
                      .realLoadProbeComplete, .canonicalPrefixBound,
                      .wineEnvironmentReady] {
                launchAuthority.clearMilestone(k)
            }
            if rt != nil { launchAuthority.earn(.runtimeResolved) }
            if runtimeCapabilityValidatedFlag { launchAuthority.earn(.runtimeCapabilityValidated) }
            if realLoadHealthy { launchAuthority.earn(.realLoadProbeComplete) }
            if canonicalPrefixEvidenceValid { launchAuthority.earn(.canonicalPrefixBound) }
            milestoneRuntimeIdentity = rt
            milestonePrefixIdentity = px
        }
    }

    /// Begin a new Steam timing attempt. Resets stage/timing/failure and the
    /// attempt generation, reconciles still-current Wine evidence (FIX C).
    ///
    /// FIX A (FIX4 §4): a sealed but UNCONSUMED current-attempt decision —
    /// e.g. one established by runtime selection before this attempt — is
    /// transferred into exactly the next single attempt by re-sealing its
    /// generation to the current attempt generation. A completed or failed
    /// attempt's decision is always nil here (consumed/cleared), so it can
    /// never be resurrected as authority for this attempt.
    func beginSteamAttempt() {
        reconcileMilestoneEvidence()
        launchAuthority.beginSteamAttempt()
        attemptGeneration &+= 1
        if let sealed = currentAttemptValidation {
            currentAttemptValidation = CurrentAttemptValidation(
                fingerprint: sealed.fingerprint,
                path: sealed.path,
                generation: attemptGeneration
            )
        }
        launchCache.invalidateIfFailed()
    }

    /// Full reset of a brand-new validation (clears all evidence).
    func resetLaunchValidation() {
        launchAuthority.reset()
        attemptGeneration &+= 1
        attemptFingerprint = nil
        lastValidationPath = nil
        currentAttemptValidation = nil // no stale authority past a reset (FIX4 §4)
        milestoneRuntimeIdentity = nil
        milestonePrefixIdentity = nil
    }

    /// Advance the launch stage through the single authority, REQUIRING the
    /// transition to be admitted (FIX B). On rejection the attempt is failed
    /// and no success is recorded.
    @discardableResult
    func requireLaunchTransition(to stage: LaunchPipelineStage) -> LaunchTransitionResult {
        let result = launchAuthority.transition(to: stage)
        if result != .admitted {
            launchAuthority.fail()
            launchCache.invalidate()
            lastValidationPath = nil
            currentAttemptValidation = nil // cleared on failure (FIX4 §4)
        }
        return result
    }

    /// Advance the launch stage without requiring admission (best-effort; the
    /// caller must check the result). Prefer ``requireLaunchTransition(to:)``.
    @discardableResult
    func advanceLaunch(to stage: LaunchPipelineStage) -> LaunchTransitionResult {
        launchAuthority.transition(to: stage)
    }

    /// Current attempt generation (for the stale-observer guard).
    var currentAttemptGeneration: UInt64 { attemptGeneration }

    /// Earn a Wine milestone from real production evidence.
    func earnWineMilestone(_ key: WineMilestoneKey) {
        launchAuthority.earn(key)
    }

    /// Clear a Wine milestone on identity change (FIX C).
    func clearWineMilestone(_ key: WineMilestoneKey) {
        launchAuthority.clearMilestone(key)
    }

    /// Record a timing segment from a production boundary.
    func recordLaunchTimingSegment(_ segment: LaunchTimingSegment, milliseconds ms: Int64) {
        launchAuthority.record(segment, milliseconds: ms)
    }

    /// Mark the launch attempt failed (clears success, invalidates cache).
    func failLaunchAttempt() {
        launchAuthority.fail()
        launchCache.invalidate()
        lastValidationPath = nil
        attemptFingerprint = nil
        currentAttemptValidation = nil // cleared on failure (FIX4 §4)
    }

    /// Record a successful (admitted Steam-ready) timing sample into history.
    func recordSuccessfulTimingSample() {
        let t = launchAuthority.timing
        timingStore.record(.wineMS, milliseconds: t.winePreparationMS)
        timingStore.record(.steamProcessMS, milliseconds: t.steamProcessStartMS)
        timingStore.record(.steamReadyMS, milliseconds: t.steamReadyMS)
        timingStore.record(.totalMS, milliseconds: t.totalToSteamReadyMS)
    }

    /// Bounded ETA estimate for Steam readiness, derived from the live
    /// monotonic attempt (never a frozen zero-valued timing).
    ///
    /// U1R18-R13-FIX1-FIX4 §6 (FIX D): while `.waitingForSteam`, the elapsed
    /// authority is the LIVE monotonic total:
    ///
    /// ```text
    /// live_total_ms =
    ///     recorded winePreparationMS
    ///   + recorded steamProcessStartMS
    ///   + current monotonic steam-ready wait elapsedMS
    /// ```
    ///
    /// Elapsed is monotonic and never decreases; remaining never increases
    /// solely because time advanced; insufficient history yields nil remaining.
    var steamReadyETA: (elapsed: Int64, remaining: Int64?)? {
        let timing = launchAuthority.timing
        let liveWait = steamReadyStopwatch?.elapsedMS()
        let liveTotal = timing.winePreparationMS + timing.steamProcessStartMS + (liveWait ?? 0)
        return (liveTotal, timingStore.remainingMS(.totalMS, elapsedMS: liveTotal))
    }

    /// U1R18-R13-FIX1-FIX3 §7: bounded result of the Steam-ready terminal
    /// operation (FIX G). The production observer and tests converge on the
    /// same terminal function.
    enum SteamReadyTerminal: Equatable, Sendable {
        case ignoredStale
        case stillWaiting
        case failedValidationBinding
        case admittedReady
        case failedTransition
    }

    /// U1R18-R13-FIX1-FIX4 §4: single-use, generation-bound validation decision
    /// for the CURRENT attempt. Separated from the historical
    /// ``lastValidationPath``/``lastLaunchPath`` display:
    ///
    /// ```yaml
    /// current_attempt_validation:
    ///   contains: exact fingerprint, exact path, attempt generation
    ///   single_use: true
    ///   consumed_after_terminal_success: true
    ///   cleared_on_failure: true
    ///   may_not_be_reconstructed_from_lastValidationPath: true
    /// ```
    ///
    /// The terminal consumes exactly this decision; a prior attempt's
    /// completed decision is never resurrected as authority for a later
    /// launch. Established ONLY by the production validation orchestration
    /// (``performRealLoadPreflightOrFastPath``), or the test seam.
    private struct CurrentAttemptValidation: Equatable, Sendable {
        let fingerprint: LaunchValidationFingerprint
        let path: LaunchValidationPath
        let generation: UInt64
    }

    /// The authoritative current-attempt decision (nil once established outside
    /// the attempt). Single-use: set by the decision orchestrator, cleared on
    /// failure, consumed by the terminal.
    private var currentAttemptValidation: CurrentAttemptValidation?

    /// U1R18-R13-FIX1-FIX4 §4: deterministic production terminal seam.
    ///
    /// Consumes the current generation, monotonic elapsed boundary, observed
    /// supervisor state, and the coordinator-held generation-bound validation
    /// decision (FIX4 FIX C). Caller-supplied fingerprint/path are NOT trusted:
    /// the terminal rebuilds the current production fingerprint and requires it
    /// to equal the bound decision fingerprint. Success is published ONLY after
    /// the full ordered proof:
    ///
    ///   generation exact
    ///   → runningVisible
    ///   → current decision exists
    ///   → decision generation exact
    ///   → live fingerprint exact (material match)
    ///   → .ready transition admitted
    ///   → success timing recorded
    ///   → timing history sample
    ///   → cache success publication
    ///   → last path/history publication
    ///   → current decision consumed
    ///
    /// Any binding or transition failure fails closed: no timing sample, no
    /// cache publication, no ready success.
    @discardableResult
    func completeSteamReadyIfCurrent(
        generation: UInt64,
        observedState: GameSessionState,
        elapsedMS: Int64
    ) -> SteamReadyTerminal {
        guard attemptGeneration == generation else { return .ignoredStale }
        guard observedState == .runningVisible else { return .stillWaiting }
        guard let decision = currentAttemptValidation else {
            failLaunchAttempt()
            return .failedValidationBinding
        }
        guard decision.generation == attemptGeneration else {
            failLaunchAttempt()
            return .failedValidationBinding
        }
        // Rebuild the CURRENT production fingerprint and require an exact
        // material match with the bound decision (mutations fail closed).
        guard let liveFingerprint = buildLaunchFingerprint(
            candidateRuntimeURL: runtimeURL,
            candidateRuntimeType: runtimeSourceType
        ), liveFingerprint == decision.fingerprint else {
            failLaunchAttempt()
            return .failedValidationBinding
        }
        guard requireLaunchTransition(to: .ready) == .admitted else {
            failLaunchAttempt()
            return .failedTransition
        }
        recordLaunchTimingSegment(.steamReady, milliseconds: elapsedMS)
        recordSuccessfulTimingSample()
        recordLaunchCacheSuccess(fingerprint: decision.fingerprint)
        lastValidationPath = decision.path
        lastLaunchPath = decision.path == .fastValidation ? "fast" : "full"
        currentAttemptValidation = nil // consumed
        steamReadyStopwatch = nil
        return .admittedReady
    }

    /// Live monotonic Steam-ready elapsed while waiting (FIX F). Backed by the
    /// active monotonic stopwatch, advancing visibly during `.waitingForSteam`.
    /// Never mutates milestones, readiness, stage, timing samples, or cache.
    var liveSteamElapsedMS: Int64? {
        guard launchPipelineStage == .waitingForSteam else { return steamReadyStopwatch?.elapsedMS() }
        return steamReadyStopwatch?.elapsedMS()
    }

    /// U1R18-R13-FIX1-FIX5: deterministic launcher for the live Steam-ready
    /// wait interval. ``observeSteamReadyBoundary`` arms the same stopwatch in
    /// production; this seam lets a FIX5 test prove the active ``steamReadyETA``
    /// advances with a controllable monotonic clock. It only starts the wait
    /// interval — it never mutates decisions, milestones, stage, samples, or
    /// cache.
    @discardableResult
    func armSteamReadyWaitForTesting() -> Bool {
        guard launchPipelineStage == .waitingForSteam else { return false }
        steamReadyStopwatch = LaunchStopwatch(clock: launchClock)
        return true
    }

    /// Launch telemetry for the startup meter (FIX E/F).
    var startupTelemetry: LaunchStartupTelemetry {
        LaunchStartupTelemetry(
            stage: launchPipelineStage,
            wineProgress: wineMilestones.progress,
            wineCompleted: wineMilestones.completedCount,
            wineTotal: WineMilestones.total,
            steamElapsedMS: liveSteamElapsedMS,
            etaRemainingMS: steamReadyETA?.remaining,
            hasSufficientEtaHistory: timingStore.canEstimate(.totalMS),
            validationPath: lastValidationPath
        )
    }

    /// U1R18-R13-FIX1 §7: bounded aggregate timing history (no identity).
    var timingHistoryPayload: [String: Any] {
        timingStore.persistencePayload
    }

    /// U1R18-R13-FIX1-FIX1 §7: last-attempt breakdown from the live authority.
    var lastAttemptBreakdown: LaunchBreakdown {
        let t = launchAuthority.timing
        return LaunchBreakdown(
            winePreparationMS: t.winePreparationMS,
            steamProcessMS: t.steamProcessStartMS,
            steamReadyMS: t.steamReadyMS,
            totalMS: t.totalToSteamReadyMS,
            path: lastLaunchPath,
            failed: launchAuthority.failed
        )
    }

    // MARK: - Init

    init(
        sessionSupervisor: any GameSessionSupervising = GameSessionSupervisor(),
        installerSupervisor: any InstallerLifecycleSupervising = InstallerSupervisor(),
        prefixManager: PrefixManager = PrefixManager(),
        receiptStore: LocalAcceptanceReceiptStore = LocalAcceptanceReceiptStore(),
        launchClock: any LaunchClock = SystemLaunchClock(),
        fileIdentityProvider: any LaunchFileIdentityProviding = SystemLaunchFileIdentityProvider()
    ) {
        // Read MACSTEAM_RENDER_PROFILE env var for non-persistent profile override.
        // didSet does not fire during init, so this is safe to set before log().
        let env = ProcessInfo.processInfo.environment["MACSTEAM_RENDER_PROFILE"] ?? ""
        if let profile = SteamUIRenderProfile(rawValue: env) {
            self.steamUIRenderProfile = profile
        } else {
            self.steamUIRenderProfile = .automatic
        }

        // Read MACSTEAM_PREFIX_ROOT env var for a non-persistent prefix-root
        // override. Used by deterministic runtime A/B to exercise a candidate
        // Wine against a fresh disposable prefix instead of the canonical
        // cloverpit prefix (never touched by an unproven runtime).
        // Production (no env var) keeps the canonical prefix root.
        let prefixRootEnv = ProcessInfo.processInfo.environment["MACSTEAM_PREFIX_ROOT"] ?? ""
        let effectivePrefixManager: PrefixManager
        if prefixRootEnv.isEmpty {
            effectivePrefixManager = prefixManager
        } else {
            effectivePrefixManager = PrefixManager(prefixesRootOverride: URL(fileURLWithPath: prefixRootEnv))
        }

        self.runtimeRegistry = RuntimeRegistry(commercialPolicy: .disabled)
        // Canonical CloverPit recipe authority (U1R18-R8): the runtime recipe is
        // the single source of truth; the bundled cloverpit.json is its
        // validated serialized mirror.
        self.recipe = CloverPitRecipeAuthority.canonical

        self.sessionSupervisor = sessionSupervisor
        self.lifecycleInstaller = installerSupervisor
        self.prefixManager = effectivePrefixManager
        self.localAcceptanceReceiptStore = receiptStore
        self.buildIdentity = BuildIdentity.current()
        self.launchClock = launchClock
        self.fileIdentityProvider = fileIdentityProvider
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
        rememberCandidates(candidates)

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

        _ = await selectRuntimeCandidate(preferred)
        generateInstallerID()
    }

    /// AI-CP-STEP2: explicit selection of a single runtime type (e.g.
    /// `runtime select imported-wine`) over the production discovery +
    /// selection path. Candidates are narrowed to the requested type, then the
    /// existing registry ordering/selection rules apply. CrossOver fallback and
    /// silent System Wine fallback are both forbidden — a missing candidate
    /// returns false so the caller can report `runtime_imported_wine_not_found`.
    ///
    /// Returns true only when the requested runtime was actually selected
    /// (`state == .runtimeReady`); a real-load/capability rejection or a
    /// missing candidate returns false.
    @discardableResult
    func selectRuntime(_ type: RuntimeType) async -> Bool {
        state = .inspecting
        error = nil

        log("Selecting runtime type: \(type.rawValue)")
        let candidates = await runtimeRegistry.discover()
        rememberCandidates(candidates)
        let narrowed = candidates.filter { $0.runtimeType == type }
        for c in narrowed {
            log("  Candidate: \(c.displayName) type=\(c.runtimeType.rawValue) usable=\(c.inspection?.isUsable ?? false)")
        }

        guard let preferred = runtimeRegistry.selectExplicit(type, from: narrowed)
        else {
            state = .runtimeRequired
            error = .runtimeNotFound
            log("No \(type.rawValue) runtime found")
            return false
        }

        let selected = await selectRuntimeCandidate(preferred)
        generateInstallerID()
        return selected
    }

    /// Exact-candidate runtime selection over the production discovery +
    /// selection lane. Used by deterministic A/B: `macsteamctl runtime
    /// select-id <safe-runtime-id>` picks ONE discovered candidate by its
    /// stable safe ID (e.g. `imported-wine-WineHQStable11.app`) instead of the
    /// type-first ordering in `selectRuntime(_:)`.
    ///
    /// Returns true only when the requested candidate was actually selected
    /// (`state == .runtimeReady` after the shared real-load/capability lane).
    @discardableResult
func selectRuntime(id: String) async -> Bool {
        state = .inspecting
        error = nil

        log("Selecting runtime by id: \(id)")
        let candidates = await runtimeRegistry.discover()
        rememberCandidates(candidates)
        for c in candidates {
            log("  Candidate: \(c.id) usable=\(c.inspection?.isUsable ?? false) v\(c.inspection?.version ?? "?")")
        }

        guard let match = candidates.first(where: {
            $0.id == id && $0.inspection?.isUsable == true
        }) else {
            state = .runtimeRequired
            error = .runtimeNotFound
            log("No usable runtime candidate found for id: \(id)")
            return false
        }

        let selected = await selectRuntimeCandidate(match)
        generateInstallerID()
        return selected
    }

    /// Cache discovered candidates into a bounded snapshot projection for the
    /// control plane. Safe stable ID only — never an absolute path.
    private func rememberCandidates(_ candidates: [RuntimeCandidate]) {
        runtimeCandidatesSnapshot = candidates.map {
            ControlPlaneRuntimeCandidate(
                id: $0.id,
                name: $0.displayName,
                type: $0.runtimeType.rawValue,
                version: $0.inspection?.version,
                usable: $0.inspection?.isUsable ?? false
            )
        }
    }

    /// Shared production selection lane: real-load preflight → capability gate
    /// → `selectCandidate`. Both `inspectSystem()` and explicit runtime
    /// selection route through here so terminal and GUI share one authority.
    @discardableResult
    private func selectRuntimeCandidate(_ candidate: RuntimeCandidate) async -> Bool {        // U1R18: Real-load preflight — prove the runtime executes a Windows
        // command (and thus steam-client capability) BEFORE the capability gate.
        if let url = candidate.url {
            let wineURL = WineExecutableLayout.detect(from: url).wine
            let outcome = await performRealLoadPreflightOrFastPath(
                runtimeURL: url, wineURL: wineURL, runtimeType: candidate.runtimeType.rawValue
            )
            if !outcome.result.isHealthy {
                state = .runtimeInvalid
                error = .runtimeInspectionFailed(
                    "Wine real-load preflight failed (\(outcome.result.status.rawValue)): \(outcome.result.detail)"
                )
                log("Real-load preflight REJECTED runtime: \(outcome.result.status.rawValue)")
                return false
            }
        }

        selectCandidate(candidate)
        let selected = state == .runtimeReady
        log("Runtime selected: \(candidate.displayName) v\(candidate.inspection?.version ?? "?")")
        log("Runtime type: \(candidate.runtimeType.rawValue)")
        log("Runtime version: \(candidate.inspection?.version ?? "?")")
        if let prefixID = prefixSafeID {
            log("Prefix safe ID: \(prefixID)")
        }
        return selected
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
        // FIX C: selecting a different runtime identity clears stale runtime-bound
        // evidence so it is never carried across an identity change.
        let runtimeChanged = runtimeURL?.path != candidate.url?.path
        if runtimeChanged {
            launchAuthority.clearMilestone(.runtimeResolved)
            launchAuthority.clearMilestone(.runtimeCapabilityValidated)
            launchAuthority.clearMilestone(.realLoadProbeComplete)
            launchCache.invalidate()
        }
        self.runtimeInspection = candidate.inspection
        self.activeRuntime = candidate.runtime
        self.runtimeURL = candidate.url
        self.milestoneRuntimeIdentity = candidate.url?.path
        // U1R18-R13-FIX1-FIX1 §3.2: runtime resolved from real production evidence.
        launchAuthority.earn(.runtimeResolved)

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
            runtimeCapabilityValidatedFlag = false
            return
        }
        // U1R18-R13-FIX1-FIX1 §3.2: capability gate actually passed.
        runtimeCapabilityValidatedFlag = true
        launchAuthority.earn(.runtimeCapabilityValidated)
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

    /// Resolve the exact Steam executable that production will launch (FIX C).
    ///
    /// This is the single authority for the x86-then-fallback selection. Both the
    /// launch plan and the validation fingerprint use this exact result, so a
    /// change between the two canonical locations (or a material change at the
    /// same path) misses the previous fingerprint.
    func resolveSteamExecutable(in prefix: URL) -> URL? {
        let candidates = [
            "drive_c/Program Files (x86)/Steam/steam.exe",
            "drive_c/Program Files/Steam/steam.exe",
        ]
        for rel in candidates {
            let url = prefix.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// U1R18-R13-FIX1-FIX1 §7/§9: build the production fingerprint from the
    /// CANDIDATE being evaluated (never silently substituting the previously
    /// selected runtime). Uses bounded material identities, never raw paths.
    ///
    /// FIX B/FIX C: returns nil unless every required artifact identity is
    /// successfully obtained (regular, non-empty file) and canonical prefix
    /// evidence is valid — an invalid fingerprint is not constructible.
    func buildLaunchFingerprint(
        candidateRuntimeURL: URL?,
        candidateRuntimeType: String?
    ) -> LaunchValidationFingerprint? {
        guard let runtimeURL = candidateRuntimeURL,
              let prefix = prefixLayout?.root else { return nil }
        let imported = candidateRuntimeType == "imported_wine"
        guard imported, canonicalPrefixEvidenceValid else { return nil }
        let wineURL = WineExecutableLayout.detect(from: runtimeURL).wine
        guard let runtimeIdentity = fileIdentityProvider.identity(for: wineURL),
              runtimeIdentity.isRegularFile, runtimeIdentity.size > 0 else { return nil }
        guard let steamURL = resolveSteamExecutable(in: prefix),
              let steamIdentity = fileIdentityProvider.identity(for: steamURL),
              steamIdentity.isRegularFile, steamIdentity.size > 0 else { return nil }
        return LaunchValidationFingerprint(
            runtimeIdentity: runtimeIdentity,
            prefixSafeID: LaunchSafeID.of(prefix.path),
            prefixEvidenceValid: true,
            steamIdentity: steamIdentity,
            importedWine: true
        )
    }

    /// U1R18-R13-FIX1-FIX1 §7: whether the expensive real-load probe may be
    /// skipped for the candidate under evaluation, given a prior successful
    /// validation under the exact candidate fingerprint. All security/ownership
    /// checks still run. Fail-closed: an unconstructible fingerprint is never
    /// admissible.
    func shouldTakeLaunchFastPath(
        candidateRuntimeURL: URL?,
        candidateRuntimeType: String?
    ) -> Bool {
        guard candidateRuntimeType == "imported_wine",
              let fp = buildLaunchFingerprint(
                candidateRuntimeURL: candidateRuntimeURL,
                candidateRuntimeType: candidateRuntimeType
              ) else { return false }
        return launchCache.matchesAdmissible(fp)
    }

    /// U1R1-8-R13-FIX1-FIX3 §5: current exact validation decision for the exact
    /// artifacts that will launch.
    ///
    /// FIX4: NEVER short-circuits on ``attemptFingerprint``/``lastValidationPath``
    /// (the eliminated double-duty legacy storage). The decision is always
    /// re-sealed by the orchestrator for the exact current artifacts; the
    /// orchestrator itself takes the fast path when the launch cache proves an
    /// admissible prior healthy validation under the identical fingerprint.
    /// FIX6: narrowest module-internal visibility so the canonical FIX6 test
    /// invokes the EXACT production prelaunch orchestration that
    /// ``launchWindowsSteam`` uses. Semantics are unchanged from the private
    /// method.
    func ensureCurrentValidationDecisionBeforeLaunch() async throws -> Bool {
        guard let runtimeURL = runtimeURL else { return false }
        let wineURL = WineExecutableLayout.detect(from: runtimeURL).wine
        let outcome = await performRealLoadPreflightOrFastPath(
            runtimeURL: runtimeURL,
            wineURL: wineURL,
            runtimeType: runtimeSourceType
        )
        return outcome.result.isHealthy
    }

    /// U1R18-R13-FIX1-FIX1 §7: record a successful full validation + admitted
    /// Steam-ready boundary so a later identical attempt may use the fast path.
    /// Binds the exact attempt fingerprint.
    func recordLaunchCacheSuccess(fingerprint: LaunchValidationFingerprint?) {
        guard let fp = fingerprint else { return }
        launchCache.recordSuccess(fingerprint: fp)
    }

    /// Test-only seam: establish a validation decision for a candidate without
    /// running a real probe. Binds the attempt fingerprint to the candidate.
@MainActor
    func setValidationDecisionForTesting(
        path: LaunchValidationPath, healthy: Bool, runtimeURL: URL?
    ) {
        let fp = buildLaunchFingerprint(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine")
        attemptFingerprint = fp
        lastValidationPath = path
        if let fp {
            // FIX4 §4: the test seam seals the SAME generation-bound current
            // decision the production orchestrator seals, so the terminal
            // consumes an identical contract. `beginSteamAttempt()` transfers
            // an un-consumed seal into exactly the next attempt.
            currentAttemptValidation = CurrentAttemptValidation(
                fingerprint: fp,
                path: path,
                generation: attemptGeneration
            )
        }
        realLoadHealthy = healthy
        realLoadResult = WineRealLoadResult(
            status: healthy ? .healthy : .launchFailed,
            detail: "test-seeded", windowsVersion: nil, exitCode: healthy ? 0 : 1
        )
    }

    /// U1R18-R13-FIX1-FIX1 §7/§11: run the real-load probe for the candidate
    /// unless an admissible fast path allows skipping it. Both paths coherently
    /// update real-load state and the real-load validation milestone.
    ///
    /// Returns (result, path). The path is frozen here, BEFORE any cache
    /// publication, so a full validation is never relabelled fast.
    @discardableResult
    func performRealLoadPreflightOrFastPath(
        runtimeURL: URL,
        wineURL: URL,
        runtimeType: String?
    ) async -> (result: WineRealLoadResult, path: LaunchValidationPath) {
        let candidateURL = runtimeURL
        let candidateType = runtimeType ?? runtimeSourceType

        if shouldTakeLaunchFastPath(
            candidateRuntimeURL: candidateURL,
            candidateRuntimeType: candidateType
        ) {
            // Fast validation: prior healthy validation re-admitted under the
            // exact candidate fingerprint. No real probe executed this attempt.
            self.realLoadHealthy = true
            self.realLoadResult = WineRealLoadResult(
                status: .healthy, detail: "fast-path", windowsVersion: nil, exitCode: 0
            )
            launchAuthority.earn(.realLoadProbeComplete)
            let fastFP = buildLaunchFingerprint(
                candidateRuntimeURL: candidateURL,
                candidateRuntimeType: candidateType
            )
            attemptFingerprint = fastFP
            lastValidationPath = .fastValidation
            lastLaunchPath = "fast"
            if let fastFP {
                // FIX4 §4: seal the authoritative current-attempt decision
                // (fast) bound to the current attempt generation.
                currentAttemptValidation = CurrentAttemptValidation(
                    fingerprint: fastFP,
                    path: .fastValidation,
                    generation: attemptGeneration
                )
            }
            return (result: self.realLoadResult ?? WineRealLoadResult(
                status: .healthy, detail: "fast-path", windowsVersion: nil, exitCode: 0
            ), path: .fastValidation)
        }

        // Full validation: the probe actually executes.
        let result = await realLoadProbeExecution(
            runtimeURL, wineURL, prefixManager.prefixesRoot
        )
        self.realLoadResult = result
        self.realLoadHealthy = result.isHealthy
        // U1R18-R13-FIX1-FIX1 §3.2: healthy production real-load evidence earns
        // the probe milestone (not merely "probe was called").
        if result.isHealthy {
            launchAuthority.earn(.realLoadProbeComplete)
        } else {
            launchCache.invalidate()
        }
        let fullFP = buildLaunchFingerprint(
            candidateRuntimeURL: candidateURL,
            candidateRuntimeType: candidateType
        )
        attemptFingerprint = fullFP
        lastValidationPath = .fullValidation
        lastLaunchPath = "full"
        if let fullFP {
            // FIX4 §4: seal the authoritative current-attempt decision (full),
            // generated-bound, before cache publication (never relabelled fast).
            currentAttemptValidation = CurrentAttemptValidation(
                fingerprint: fullFP,
                path: .fullValidation,
                generation: attemptGeneration
            )
        }
        log("Real-load preflight: \(result.status.rawValue) — \(result.detail)")
        if let version = result.windowsVersion {
            log("Real-load Windows version: \(version)")
        }
        return (result: result, path: .fullValidation)
    }

    /// U1R18-R13-FIX1-FIX1 §7: run the real-load preflight against the given
    /// runtime URL.
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
        // U1R18-R13-FIX1-FIX1 §3.2: healthy production real-load evidence earns
        // the probe milestone (not merely "probe was called").
        if result.isHealthy {
            launchAuthority.earn(.realLoadProbeComplete)
        }
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
        let outcome = await performRealLoadPreflightOrFastPath(
            runtimeURL: url, wineURL: wineURL, runtimeType: candidate.runtimeType.rawValue
        )
        if !outcome.result.isHealthy {
            state = .runtimeInvalid
            error = .runtimeInspectionFailed(
                "Wine real-load preflight failed (\(outcome.result.status.rawValue)): \(outcome.result.detail)"
            )
            log("Real-load preflight REJECTED runtime: \(outcome.result.status.rawValue)")
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

    /// Wine prefix bootstrap (wineboot) can settle more slowly in-app than
    /// under direct invocation. Bounded accommodation for Wine 11 prefixes:
    /// keep this explicitly scoped to prefix creation — not the general
    /// command timeout, and not a global runner default.
    static let prefixBootstrapTimeout: TimeInterval = 300

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
                    // U1R18-R13-ACCEPTANCE3-FIX1: steam-ready is NEVER claimed
                    // from the prefix signature alone. Pass through the single
                    // reconciliation authority (payload projection) before any
                    // early return.
                    let reconciliation = reconcileSteamInstallStateFromCurrentPrefix()
                    if reconciliation.ready {
                        state = .steamReady
                        log("steam.exe FOUND in canonical prefix — advancing to Steam ready")
                    } else {
                        // Agreement enforcement: the signature claims steam.exe
                        // but the payload authority rejected it (zero-byte,
                        // missing, or interrupted-hold). NOT steamReady, NOT
                        // verifiedComplete — raise the recovery projection with
                        // guidance until the operator resolves.
                        log("steam.exe signature present but reconciliation rejected (lifecycle=\(reconciliation.lifecycle.rawValue)) — NOT advancing to Steam ready")
                        state = reconciliation.projectedSetupState
                        error = .steamInstallationFailed(
                            "Steam.exe was claimed in the prefix signature but the payload did not reconcile "
                            + "(lifecycle=\(reconciliation.lifecycle.rawValue)). Verify or reinstall Steam."
                        )
                    }
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
                    // U1R18-R13-ACCEPTANCE3-FIX1: single reconciliation authority.
                    reconcileSteamInstallStateFromCurrentPrefix()
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
                // Resolve via the detected layout (standard OR .app bundle) —
                // never assume `<root>/bin/wineboot`.
                let layout = WineExecutableLayout.detect(from: runtimeURL)
                winebootURL = try layout.ensureWineboot()
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
                timeout: Self.prefixBootstrapTimeout
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

            // Reconcile Steam install state from the current prefix (single
            // reconciliation authority — U1R18-R13-ACCEPTANCE3-FIX1).
            reconcileSteamInstallStateFromCurrentPrefix()

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

    /// U1R18-R13-ACCEPTANCE3-FIX1: the single coordinator-owned reconciliation
    /// of Steam install truth (inspection + lifecycle + setup state) from the
    /// CURRENT canonical prefix payload.
    ///
    /// Success (a regular, non-empty `steam.exe` in the canonical prefix, no
    /// interrupted-hold) projects `steamInstalled = true`,
    /// `steamInstallLifecycle = .verifiedComplete`, and ready. Any rejected
    /// payload (interrupted-hold → `.interrupted`; zero-byte/invalid/missing →
    /// `.absent`) projects NOT ready and NOT `.verifiedComplete`.
    ///
    /// This is the single source of truth for Steam readiness: the
    /// existing-prefix reuse branch, the adopted-prefix branch, and
    /// ``recheckSteam()`` all route through here.
    @discardableResult
    func reconcileSteamInstallStateFromCurrentPrefix() -> SteamReconciliation {
        let fm = FileManager.default
        guard let layout = prefixLayout else {
            steamInspection = nil
            steamInstallLifecycle = .absent
            return SteamReconciliation(
                lifecycle: .absent,
                steamInstalled: false,
                ready: false,
                interruptedHoldPresent: false
            )
        }

        // Payload authority: canonical prefix only. The hold file marks an
        // interrupted installation (quarantined steam.exe); it never validates.
        let steamDir = layout.root.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let holdFile = steamDir.appendingPathComponent("steam.exe.macsteam-install-hold")
        let held = fm.fileExists(atPath: holdFile.path)

        // Single production resolver (x86 then fallback) — the SAME authority
        // used for launch and fingerprint building.
        let steamExe = resolveSteamExecutable(in: layout.root)

        var valid = false
        if let exe = steamExe {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: exe.path, isDirectory: &isDir), !isDir.boolValue {
                let size = (try? fm.attributesOfItem(atPath: exe.path))?[.size] as? UInt64 ?? 0
                valid = size > 0
            }
        }

        let lifecycle: SteamInstallLifecycle
        if held {
            lifecycle = .interrupted
        } else if valid {
            lifecycle = .verifiedComplete
        } else {
            lifecycle = .absent
        }

        if valid, let exe = steamExe {
            steamInspection = SteamInstallationInspection(
                steamInstalled: true,
                steamExePath: exe.path.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"),
                steamVersion: nil
            )
        } else {
            steamInspection = .notFound
        }
        steamInstallLifecycle = lifecycle

        log("Steam reconciliation (canonical prefix): lifecycle=\(lifecycle.rawValue) valid=\(valid) held=\(held)")
        return SteamReconciliation(
            lifecycle: lifecycle,
            steamInstalled: valid,
            ready: lifecycle == .verifiedComplete,
            interruptedHoldPresent: held
        )
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

        // U1R18-R13-ACCEPTANCE3-FIX1: the verification decision routes through
        // the single reconciliation authority — a verified payload must be a
        // regular, non-empty steam.exe in the canonical prefix, not a manual
        // lifecycle assignment.
        let reconciliation = reconcileSteamInstallStateFromCurrentPrefix()
        guard reconciliation.ready else {
            error = .steamInstallationFailed("steam.exe not found or empty after restoration")
            return
        }
        state = .steamReady
        log("Steam installation verified complete by user")
    }

    /// Re-check Steam installation status (polling).
    ///
    /// U1R18-R13-ACCEPTANCE3-FIX1: uses the SAME single reconciliation
    /// authority. Steam-ready is projected together with lifecycle + inspection
    /// from the current canonical prefix payload; a re-check never claims
    /// ready from stale state.
    func recheckSteam() async {
        let reconciliation = reconcileSteamInstallStateFromCurrentPrefix()
        state = reconciliation.projectedSetupState
        log("Steam re-check: lifecycle=\(reconciliation.lifecycle.rawValue) ready=\(reconciliation.ready)")
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
            // U1R18-R13-ACCEPTANCE3-FIX1: any Steam-state claim from a failed
            // CloverPit re-check routes through the SINGLE reconciliation
            // authority — never a raw existence-only inspection flag. A
            // rejected payload (missing/zero-byte) never projects steamReady.
            let reconciliation = reconcileSteamInstallStateFromCurrentPrefix()
            if !reconciliation.steamInstalled {
                state = reconciliation.projectedSetupState
                log("Steam also not detected — reverting to Steam stage (lifecycle=\(reconciliation.lifecycle.rawValue))")
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

        // FIX C: single production resolver for the exact Steam executable that
        // will launch (x86 then fallback). The same resolution is used by the
        // validation fingerprint and the launch plan.
        guard let prefixRoot = prefixLayout?.root,
              let steamExe = resolveSteamExecutable(in: prefixRoot) else {
            error = .launchFailed("Steam not installed in prefix")
            state = .steamInstallerRequired
            return
        }

        log("Launching Windows Steam (idempotent)…")
        steamClientState = .launching
        // U1R18-R13-FIX1-FIX2 §6/§17: begin a fresh timing attempt, preserving
        // still-current validation evidence. Require the startingSteam
        // transition; a rejected transition fails the attempt.
        beginSteamAttempt()
        guard requireLaunchTransition(to: .startingSteam) == .admitted else {
            failLaunchAttempt()
            return
        }
        let wineStopwatch = LaunchStopwatch(clock: launchClock)

        do {
            // FIX D: ensure a current exact validation decision for the exact
            // artifacts that will launch (fast or full).
            do {
                let healthy = try await ensureCurrentValidationDecisionBeforeLaunch()
                if !healthy {
                    failLaunchAttempt()
                    return
                }
            } catch {
                failLaunchAttempt()
                return
            }

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
            // U1R18-R13-FIX1-FIX2 §4: wine preparation boundary (proven env).
            recordLaunchTimingSegment(.winePreparation, milliseconds: wineStopwatch.elapsedMS())

            guard requireLaunchTransition(to: .waitingForSteam) == .admitted else {
                failLaunchAttempt()
                return
            }
            let processStopwatch = LaunchStopwatch(clock: launchClock)
            let _ = try await sessionSupervisor.launch(
                plan: plan,
                runtimeControl: runtimeControl,
                prefixRoot: prefixURL,
                recipeID: "steam-setup",
                runtimeID: runtimeSourceType ?? "unknown",
                purpose: .steamSetup
            )
            // U1R18-R13-FIX1-FIX2 §4: steam process-launch boundary (spawn).
            recordLaunchTimingSegment(.steamProcessStart, milliseconds: processStopwatch.elapsedMS())

            log("Windows Steam session started: purpose=steamSetup, profile=\(steamUIRenderProfile.rawValue)")
            // U1R18 R1: visibility is MEASURED from the WindowServer via the
            // supervisor's observer, never guessed. Do NOT call Steam ready here.
            steamClientState = .launching
            state = .steamReady
            // U1R18-R13-FIX1-FIX2 §4/§13/§14: observe the actual admitted
            // Steam-ready boundary (runningVisible) with the attempt-generation
            // guard, before recording a successful sample.
            observeSteamReadyBoundary()
        } catch {
            self.error = .launchFailed(error.localizedDescription)
            steamClientState = .stopped
            state = .steamReady
            failLaunchAttempt()
        }
    }

    /// U1R18-R13-FIX1-FIX2 §4/§13/§14: bounded observer for the real Steam-ready
    /// boundary. Steam ready is only admitted when the supervisor reports
    /// `.runningVisible` (WindowServer evidence), never a manual assignment.
    /// A stale observer (from a previous/later attempt) must not complete this
    /// attempt: it is guarded by the attempt-generation token. The validation
    /// decision (fingerprint + path) is FROZEN here so a later attempt cannot
    /// overwrite it underneath this observer (FIX A).
    private func observeSteamReadyBoundary() {
        steamReadyStopwatch = LaunchStopwatch(clock: launchClock)
        let clock = launchClock
        let start = steamReadyStopwatch
        let generation = attemptGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = clock.nowMilliseconds() + 120_000
            while !Task.isCancelled {
                // FIX H: a stale observer must not complete a later attempt.
                guard self.attemptGeneration == generation else { return }
                if self.sessionSupervisor.state == .runningVisible {
                    let elapsed = start?.elapsedMS() ?? 0
                    _ = self.completeSteamReadyIfCurrent(
                        generation: generation,
                        observedState: self.sessionSupervisor.state,
                        elapsedMS: elapsed
                    )
                    self.steamReadyStopwatch = nil
                    return
                }
                if clock.nowMilliseconds() > deadline {
                    guard self.attemptGeneration == generation else { return }
                    self.failLaunchAttempt()
                    self.steamReadyStopwatch = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
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
                // U1R18-R13-FIX1-FIX1 §3.2: production launch environment for the
                // selected runtime/prefix was actually constructed.
                launchAuthority.earn(.wineEnvironmentReady)
                return env
            }
        }

        log("Warning: RuntimeDependencyLayout unavailable, using basic environment")
        launchAuthority.earn(.wineEnvironmentReady)
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
            wineURL = WineExecutableLayout.detect(from: runtimeURL).wine
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
            beginLocalAcceptance(for: session)
        } catch {
            self.error = .launchFailed(error.localizedDescription)
            state = .cloverPitReady
            invalidateAndDiscardLocalAcceptance(reason: .monitorCancelled)
        }
    }

    // MARK: - U1R18-R11 Local acceptance

    /// Seed and start the fail-closed acceptance authority for a committed game
    /// session. Prerequisites are reconstructed from current derived state; the
    /// deadline clock is injectable but production uses wall-clock time.
    private func beginLocalAcceptance(for session: GameSession) {
        // Prerequisite gate: only imported Wine admitted as the runtime source.
        let source = localReceiptSourceType(from: runtimeSourceType)
        var prerequisites = LocalAcceptancePrerequisites()
        prerequisites.runtimeSourceType = source
        prerequisites.runtimeRealLoadHealthy = realLoadHealthy
        prerequisites.canonicalPrefixBound = canonicalPrefixEvidenceValid
        prerequisites.steamInstallVerified = steamInstallationReady
        prerequisites.cloverpitInstallReady = cloverPitInspection?.isReady ?? false
        prerequisites.supervisedGameSessionStarted = true

        let authority = LocalRuntimeAcceptanceAuthority(
            receiptPersister: { [store = localAcceptanceReceiptStore] receipt in
                switch store.saveAccepted(receipt) {
                case .saved: return .persisted(receipt)
                default: return .failed
                }
            }
        )
        authority.setPrerequisites(prerequisites)
        acceptanceGenerationCounter &+= 1
        authority.beginCandidate(for: session, generation: acceptanceGenerationCounter)
        localAcceptanceAuthority = authority
        startLocalAcceptanceMonitor()
    }

    /// U1R18-R13-ACCEPTANCE3-FIX1: acceptance derives Steam verification
    /// exclusively from the reconciled canonical truth (projected by the
    /// single reconciliation authority). No split authority: a raw inspection
    /// `steamInstalled` flag can never substitute for a reconciled
    /// `.verifiedComplete` lifecycle.
    private var steamInstallationReady: Bool {
        steamInstallLifecycle == .verifiedComplete
    }

    private var acceptanceGenerationCounter: UInt64 = 0

    private func startLocalAcceptanceMonitor() {
        localAcceptanceMonitorTask?.cancel()
        localAcceptanceMonitorTask = Task { @MainActor [weak self] in
            await self?.feedLocalAcceptanceLoop()
        }
    }

    /// Dedicated observation loop. Reduced to a plain machine snapshot before
    /// handing to the authority, so the authority stays decision-only.
    private func feedLocalAcceptanceLoop() async {
        guard let authority = localAcceptanceAuthority else { return }
        while !Task.isCancelled {
            let snapshot = await makeLocalAcceptanceSnapshot()
            authority.observe(snapshot)
            if authority.isAccepted || authority.isInvalidated || authority.isBlocked {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func makeLocalAcceptanceSnapshot() async -> LocalAcceptanceMachineSnapshot {
        let census = await sessionSupervisor.processCensus()
        return LocalAcceptanceMachineSnapshot(
            sessionID: sessionSupervisor.activeSession?.sessionID,
            sessionPurpose: sessionSupervisor.activeSession?.purpose,
            recipeID: sessionSupervisor.activeSession?.recipeID,
            sessionState: sessionSupervisor.state,
            censusState: census.state
        )
    }

    /// Cancels the observation task while preserving the authority and its
    /// earned/receipt state. Used after a successful acceptance so the terminal
    /// accepted state is not clobbered.
    private func cancelLocalAcceptanceObservationPreservingAuthority() {
        localAcceptanceMonitorTask?.cancel()
        localAcceptanceMonitorTask = nil
    }

    /// Invalidates and discards the authority outright. Used to abandon an
    /// acceptance (e.g. failed launch).
    private func invalidateAndDiscardLocalAcceptance(reason: LocalAcceptanceBlocker) {
        localAcceptanceMonitorTask?.cancel()
        localAcceptanceMonitorTask = nil
        localAcceptanceAuthority?.invalidate(reason)
        localAcceptanceAuthority = nil
    }

    /// User confirmed seeing the CloverPit window.
    func confirmWindow() {
        launchPhase = .windowConfirmed
    }

    /// User confirmed seeing main menu.
    func confirmMainMenu() {
        launchPhase = .mainMenuConfirmed
        _ = localAcceptanceAuthority?.confirmMainMenu()
    }

    /// Run the cleanup gate and finalize acceptance only on a clean cleanup.
    func completeLocalAcceptance() async -> LocalAcceptanceActionResponse {
        guard let authority = localAcceptanceAuthority else {
            return .rejected(.monitorCancelled)
        }
        let response = await authority.requireCompletion {
            await self.stopAllForApplicationTermination()
        }
        if response == .accepted {
            // Preserve the authority (and earned receipt); only the observation
            // task is stopped. The authority now sits in a terminal accepted
            // state and is never mutated again.
            cancelLocalAcceptanceObservationPreservingAuthority()
        }
        return response
    }

    /// Test seam: install a fully-prepared acceptance authority so tests can
    /// drive the completion/persistence path deterministically without a live
    /// supervision session or visibility window. The monitor is intentionally
    /// not started; only the authority identity is replaced.
    func installAcceptanceForTesting(_ authority: LocalRuntimeAcceptanceAuthority?) {
        localAcceptanceMonitorTask?.cancel()
        localAcceptanceMonitorTask = nil
        localAcceptanceAuthority = authority
    }

    /// User confirmed the input response (production API; previously only the
    /// menu was confirmable from the production UI).
    @discardableResult
    func confirmInputResponse() -> LocalAcceptanceActionResponse {
        guard let authority = localAcceptanceAuthority else {
            return .rejected(.monitorCancelled)
        }
        return authority.confirmInputResponse()
    }

    private func localReceiptSourceType(from string: String?) -> LocalReceiptSourceType {
        switch string {
        case "managed_wine": return .managedWine
        case "imported_wine": return .importedWine
        case "system_wine": return .systemWine
        case "crossover": return .crossover
        default: return .runtime
        }
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
        // Control-plane telemetry: record the intent + source page exactly as
        // the production authority sees them (never inferred later).
        self.lastNavigationIntent = intent
        self.lastNavigationFromPage = currentPage

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

    // MARK: - Control-plane canonical actions

    /// U1R18-R13-ACCEPTANCE4-STATE-MIRROR: single production authority for the
    /// machine-readable action model consumed by BOTH the SwiftUI footer and the
    /// terminal mirror. There is deliberately NO terminal-only shadow logic —
    /// `enabled`/`target`/`disabled_reason` are pure projections of the same
    /// `currentPage` + `computePageCompletion()` + `lastNavigationResult` state
    /// the reducer validates against.
    var canonicalControlPlaneActions: [String: ControlPlaneAction] {
        let pages = InstallerPage.allCases
        let index = pages.firstIndex(of: currentPage) ?? 0
        let hasPrev = index > 0
        let hasNext = index + 1 < pages.count
        let completion = computePageCompletion()
        let activeOp = hasActiveOperation
        let cleanupRequired = isCleanupRequired

        // BACK / NEXT derive from the same gates the reducer enforces:
        // cleanup + active operation + page completion.
        var actions: [String: ControlPlaneAction] = [:]

        let backTarget = hasPrev ? pages[index - 1].rawValue : currentPage.rawValue
        actions["back"] = ControlPlaneAction(
            id: "back",
            enabled: hasPrev && !cleanupRequired && !activeOp,
            source: currentPage.rawValue,
            target: backTarget,
            disabled_reason: backDisabledReason(hasPrev: hasPrev, cleanup: cleanupRequired, active: activeOp)
        )

        let nextTarget = hasNext ? pages[index + 1].rawValue : currentPage.rawValue
        let pageComplete = completion[currentPage] == true
        actions["next"] = ControlPlaneAction(
            id: "next",
            enabled: hasNext && !cleanupRequired && !activeOp && pageComplete,
            source: currentPage.rawValue,
            target: nextTarget,
            disabled_reason: nextDisabledReason(hasNext: hasNext, cleanup: cleanupRequired, active: activeOp, complete: pageComplete)
        )

        // RETRY: available exactly when an error is present on the current page.
        actions["retry"] = ControlPlaneAction(
            id: "retry",
            enabled: error != nil,
            source: currentPage.rawValue,
            target: currentPage.rawValue,
            disabled_reason: error == nil ? "No error to retry." : nil
        )

        // AI-CP-STEP2: explicit runtime-type selection on the runtime surface
        // (feeds `macsteamctl runtime select imported-wine`). Reuses the same
        // discovery + capability + real-load production path as inspectSystem.
        let onRuntimeSurface = currentPage == .runtime
        actions["runtime.select"] = ControlPlaneAction(
            id: "runtime.select",
            enabled: onRuntimeSurface && !activeOp && state != .inspecting,
            source: "runtime",
            target: "runtime",
            disabled_reason: !onRuntimeSurface ? "Runtime surface is not active." : activeOp ? "An operation is in progress." : state == .inspecting ? "Runtime inspection is in progress." : nil
        )

        // Exact-candidate runtime selection feeds `macsteamctl runtime
        // select-id <safe-runtime-id>` for deterministic A/B. Same gate as the
        // type-based `runtime.select`.
        actions["runtime.select_id"] = ControlPlaneAction(
            id: "runtime.select_id",
            enabled: onRuntimeSurface && !activeOp && state != .inspecting,
            source: "runtime",
            target: "runtime",
            disabled_reason: !onRuntimeSurface ? "Runtime surface is not active." : activeOp ? "An operation is in progress." : state == .inspecting ? "Runtime inspection is in progress." : nil
        )

        // Prefix preparation: enabled on the environment surface while the
        // canonical prefix is not yet bound and no creation is in flight.
        let prefixReady = runtimeURL != nil && !canonicalPrefixEvidenceValid && !isCreatingPrefix
        actions["prefix.prepare"] = ControlPlaneAction(
            id: "prefix.prepare",
            enabled: prefixReady,
            source: "environment",
            target: "environment",
            disabled_reason: prefixDisabledReason(runtimeSelected: runtimeURL != nil, bound: canonicalPrefixEvidenceValid, creating: isCreatingPrefix)
        )

        // Steam installer selection + install on the steamInstaller surface.
        let installerSelected = selectedInstaller != nil
        let steamAlreadyComplete = steamInstallLifecycle == .verifiedComplete
        let onInstallerSurface = currentPage == .steamInstaller
        actions["steam.select_installer"] = ControlPlaneAction(
            id: "steam.select_installer",
            enabled: onInstallerSurface && !installerSelected && !steamAlreadyComplete,
            source: "steamInstaller",
            target: "steamInstaller",
            disabled_reason: !onInstallerSurface ? "Steam installer surface is not active." : steamAlreadyComplete ? "Steam is already installed." : installerSelected ? "Installer already selected." : nil
        )
        actions["steam.install"] = ControlPlaneAction(
            id: "steam.install",
            enabled: onInstallerSurface && installerSelected && !steamAlreadyComplete && !activeOp,
            source: "steamInstaller",
            target: "steamInstaller",
            disabled_reason: !onInstallerSurface ? "Steam installer surface is not active." : !installerSelected ? "Select a Steam installer first." : steamAlreadyComplete ? "Steam is already installed." : activeOp ? "An operation is in progress." : nil
        )

        // Steam client re-check + launch on the steamClient surface.
        let onClientSurface = currentPage == .steamClient
        let launchable = steamInstallEvidence.canLaunchSteam && !isLaunchingSteam
        actions["steam.recheck"] = ControlPlaneAction(
            id: "steam.recheck",
            enabled: onClientSurface,
            source: "steamClient",
            target: "steamClient",
            disabled_reason: onClientSurface ? nil : "Steam client surface is not active."
        )
        actions["steam.launch"] = ControlPlaneAction(
            id: "steam.launch",
            enabled: launchable && onClientSurface,
            source: "steamClient",
            target: "steamClient",
            disabled_reason: onClientSurface ? (isLaunchingSteam ? "Steam launch is already in progress." : !steamInstallEvidence.canLaunchSteam ? "Steam is not ready to launch." : nil) : "Steam client surface is not active."
        )

        // Steam diagnose: read-only live capture of the on-screen error, Steam
        // logs, and process output. Always available — it is pure observation.
        actions["steam.diagnose"] = ControlPlaneAction(
            id: "steam.diagnose",
            enabled: true,
            source: "steamClient",
            target: "steamClient",
            disabled_reason: nil
        )

        // CloverPit check + launch. cloverpit.check is a read-only file
        // inspection (recheckCloverPit) that is also safe to run on the Steam
        // Client surface while Steam finalizes a staged payload — the terminal
        // polls it there instead of looping on the cloverPit surface.
        let onCloverPitSurface = currentPage == .cloverPit
        let onCloverPitOrSteamSurface = onCloverPitSurface || currentPage == .steamClient
        let cloverReady = cloverPitInspection?.isReady == true
        actions["cloverpit.check"] = ControlPlaneAction(
            id: "cloverpit.check",
            enabled: onCloverPitOrSteamSurface,
            source: "cloverPit",
            target: "cloverPit",
            disabled_reason: onCloverPitOrSteamSurface ? nil : "CloverPit surface is not active."
        )
        actions["cloverpit.launch"] = ControlPlaneAction(
            id: "cloverpit.launch",
            enabled: onCloverPitSurface && cloverReady && !activeOp,
            source: "cloverPit",
            target: "cloverPit",
            disabled_reason: !onCloverPitSurface ? "CloverPit surface is not active." : !cloverReady ? "CloverPit is not ready to launch." : activeOp ? "An operation is in progress." : nil
        )

        // Session stop: enabled whenever a supervised session is running.
        actions["session.stop"] = ControlPlaneAction(
            id: "session.stop",
            enabled: sessionSupervisorIsRunning,
            source: "session",
            target: "session",
            disabled_reason: sessionSupervisorIsRunning ? nil : "No active session to stop."
        )

        return actions
    }

    private func backDisabledReason(hasPrev: Bool, cleanup: Bool, active: Bool) -> String? {
        if cleanup { return "Cleanup is required before navigating back." }
        if active { return "An operation is active; stop it first." }
        if !hasPrev { return "Already on the first screen." }
        return nil
    }

    private func nextDisabledReason(hasNext: Bool, cleanup: Bool, active: Bool, complete: Bool) -> String? {
        if cleanup { return "Cleanup is required before navigating next." }
        if active { return "An operation is active; stop it first." }
        if !hasNext { return "Already on the last screen." }
        if !complete { return "Current screen is not complete yet." }
        return nil
    }

    private func prefixDisabledReason(runtimeSelected: Bool, bound: Bool, creating: Bool) -> String? {
        if !runtimeSelected { return "Select a runtime first." }
        if bound { return "Canonical prefix is already bound." }
        if creating { return "Prefix creation is already in progress." }
        return nil
    }

    // MARK: - Control-plane snapshot projection

    /// U1R18-R13-ACCEPTANCE4-STATE-MIRROR: project the CURRENT production state
    /// into a bounded, machine-readable snapshot. Pure read of coordinator
    /// state; no process/WindowServer probing of its own (steam/cloverpit
    /// flags are the production supervisor's already-observed state).
    func controlPlaneSnapshot() async -> ControlPlaneSnapshot {
        let installerOp = await lifecycleInstaller.snapshot()
        let evidence = steamInstallEvidence
        let session = activeSession
        let supervisorState = sessionSupervisorState
        let steamDiagnostics = await steamDiagnosticsProjection()

        // Session-purpose split: Steam-owned sessions are `.steamSetup`;
        // game sessions are `.game`. Visibility comes from the supervisor's
        // WindowServer observer only (runningVisible), never guessed.
        let steamSession = session?.purpose == .steamSetup
        let steamRunning = steamSession
            ? sessionSupervisorIsRunning
            : (steamClientState == .runningVisible || steamClientState == .runningHidden)
        let steamVisible = steamSession
            ? supervisorState == .runningVisible
            : steamClientState == .runningVisible
        // U1R18 R1: the client-state label follows the same live observer the
        // booleans above use, so `status` never reports launching while the
        // WindowServer already shows the Steam window.
        let steamClientLabel = steamSession
            ? steamClientStateLabel(SteamClientState(sessionState: supervisorState))
            : steamClientStateLabel(steamClientState)
        let gamePurpose = session?.purpose == .game
        let cloverRunning = gamePurpose && sessionSupervisorIsRunning
        let cloverVisible = gamePurpose && supervisorState == .runningVisible
        let inspection = cloverPitInspection

        return ControlPlaneSnapshot(
            schema_version: 1,
            build_sha: buildIdentity.commitSHA,
            screen: currentPage.rawValue,
            setup_state: state.rawValue,
            runtime: ControlPlaneRuntime(
                type: runtimeSourceType ?? "unknown",
                selected: runtimeURL != nil,
                real_load_healthy: realLoadHealthy,
                candidates: runtimeCandidatesSnapshot
            ),
            prefix: ControlPlanePrefix(
                bound: canonicalPrefixEvidenceValid,
                valid: prefixInspection?.isValid ?? false
            ),
            steam: ControlPlaneSteam(
                exe_present: evidence.steamExePresent,
                installed: steamInstallLifecycle == .verifiedComplete,
                lifecycle: steamInstallLifecycle.rawValue,
                running: steamRunning,
                window_visible: steamVisible,
                client_state: steamClientLabel,
                visible_error: steamDiagnostics.visibleError,
                observed_errors: steamDiagnostics.observedErrors,
                stdout_tail: steamDiagnostics.stdoutTail,
                stderr_tail: steamDiagnostics.stderrTail
            ),
            cloverpit: ControlPlaneCloverPit(
                ready: inspection?.isReady ?? false,
                running: cloverRunning,
                window_visible: cloverVisible,
                install_state: inspection?.installState.rawValue ?? "notFound",
                manifest_present: inspection?.manifestPresent ?? false,
                install_directory_resolved: inspection?.installDirectoryResolved ?? false,
                executable_present: inspection?.executablePresent ?? false,
                canonical_install_present: inspection?.canonicalInstallPresent ?? false,
                download_payload_present: inspection?.downloadPayloadPresent ?? false
            ),
            session: ControlPlaneSession(
                purpose: session?.purpose.rawValue ?? "none",
                running: sessionSupervisorIsRunning,
                window_visible: supervisorState == .runningVisible
            ),
            actions: canonicalControlPlaneActions,
            installer: ControlPlaneInstaller(
                session: installerID.isEmpty ? "none" : installerID,
                phase: installerOp?.phase.rawValue ?? "idle",
                active: installerOp?.phase.isActive ?? false,
                message: latestInstallerMessage(),
                last_error: installerOp?.lastError.map(Self.redactMessage)
            ),
            last_transition: controlPlaneTransition(),
            last_error: controlPlaneError()
        )
    }

    /// Bounded latest installer log line (single message, no full-log copy).
    private func latestInstallerMessage() -> String? {
        let lines = installerLog.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return Self.redactMessage(String(last.prefix(200)))
    }

    // MARK: - Steam live diagnostics (STEP3-FIX2)

    private struct SteamDiagnosticsProjection {
        var visibleError: ControlPlaneVisibleError?
        var observedErrors: [ControlPlaneSteamLogEntry]
        var stdoutTail: String?
        var stderrTail: String?
    }

    private var lastSteamDiagnosticsCapture: Date?
    private var cachedSteamDiagnostics: SteamDiagnosticsProjection?

    /// Throttled projection of live Steam error evidence for the snapshot.
    /// Re-captures at most once every 2 seconds unless `force` is set (the
    /// `steam.diagnose` action forces a fresh read).
    private func steamDiagnosticsProjection(force: Bool = false) async -> SteamDiagnosticsProjection {
        let now = Date()
        if !force,
            let cached = cachedSteamDiagnostics,
            let last = lastSteamDiagnosticsCapture,
            now.timeIntervalSince(last) < 2 {
            return cached
        }
        let projection = await computeSteamDiagnostics(includeOCR: force)
        cachedSteamDiagnostics = projection
        lastSteamDiagnosticsCapture = now
        return projection
    }

    /// Read the ACTUAL on-screen Steam error (Accessibility first, OCR in the
    /// forced diagnose path) plus Steam's own generic logs and the supervised
    /// process stdout/stderr. Ownership-bounded: only session-proven owned
    /// PIDs are inspected. Permission deficits are reported, never masked.
    private func computeSteamDiagnostics(includeOCR: Bool) async -> SteamDiagnosticsProjection {
        let owned = await sessionSupervisor.ownedSteamWindowOwnerPIDs() ?? []
        let pids = Array(owned)

        var visibleError: ControlPlaneVisibleError?
        if !pids.isEmpty {
            let accessibility = SteamLiveDiagnostics.readAccessibility(ownerPIDs: pids)
            if accessibility.permissionDenied {
                visibleError = ControlPlaneVisibleError(
                    present: false,
                    permission_required: "accessibility"
                )
            } else if let title = accessibility.title {
                visibleError = ControlPlaneVisibleError(
                    present: true,
                    source: "accessibility",
                    title: SteamLiveDiagnostics.redact(title, maxLength: 200),
                    message: accessibility.messages.first.map {
                        SteamLiveDiagnostics.redact($0, maxLength: 200)
                    }
                )
            } else if let message = accessibility.messages.first {
                visibleError = ControlPlaneVisibleError(
                    present: true,
                    source: "accessibility",
                    title: nil,
                    message: SteamLiveDiagnostics.redact(message, maxLength: 200)
                )
            }

            // OCR fallback: only when Accessibility produced no text, only in
            // the forced diagnose path (Vision recognition is not per-tick).
            if includeOCR, visibleError?.present != true {
                let ocr = await SteamLiveDiagnostics.readOCR(ownerPIDs: pids)
                if ocr.permissionDenied {
                    visibleError = visibleError ?? ControlPlaneVisibleError(
                        present: false,
                        permission_required: "screen_recording"
                    )
                } else if let first = ocr.texts.first {
                    visibleError = ControlPlaneVisibleError(
                        present: true,
                        source: "ocr",
                        title: nil,
                        message: SteamLiveDiagnostics.redact(first, maxLength: 200)
                    )
                }
            }
        }

        let observedErrors = SteamLiveDiagnostics.scanSteamLogs(directory: steamLogsDirectory())
        let outputs = await sessionSupervisor.steamProcessDiagnostics()
        return SteamDiagnosticsProjection(
            visibleError: visibleError,
            observedErrors: observedErrors,
            stdoutTail: outputs.stdout.isEmpty ? nil : SteamLiveDiagnostics.redact(
                String(outputs.stdout.suffix(4000)), maxLength: 4000
            ),
            stderrTail: outputs.stderr.isEmpty ? nil : SteamLiveDiagnostics.redact(
                String(outputs.stderr.suffix(4000)), maxLength: 4000
            )
        )
    }

    /// Detect Steam's own generic log directory in the canonical prefix.
    private func steamLogsDirectory() -> URL? {
        guard let prefix = prefixLayout?.root else { return nil }
        let candidates = [
            prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/logs"),
            prefix.appendingPathComponent("drive_c/Program Files/Steam/logs"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// `steam.diagnose`: force a fresh live capture so the next snapshot and
    /// doctor report reflect what is actually on screen right now.
    func refreshSteamDiagnostics() async {
        _ = await steamDiagnosticsProjection(force: true)
    }


    /// The last navigation transition projected from the production record.
    private func controlPlaneTransition() -> ControlPlaneTransition? {
        guard let intent = lastNavigationIntent else { return nil }
        return ControlPlaneTransition(
            from: lastNavigationFromPage?.rawValue,
            action: intent.rawValue,
            to: currentPage.rawValue,
            accepted: lastNavigationResult?.accepted ?? false
        )
    }

    /// The current coordinator error, bounded + redacted (fail-closed: never
    /// leaks raw error text, paths, or identity into the control plane).
    private func controlPlaneError() -> ControlPlaneError? {
        guard let error else { return nil }
        return ControlPlaneError(
            subsystem: "coordinator",
            code: Self.errorCaseLabel(error),
            message: Self.redactMessage(error.localizedDescription),
            screen: currentPage.rawValue,
            last_action: lastNavigationIntent?.rawValue
        )
    }

    /// Bound length and redact path-like fragments. Shared by snapshot +
    /// installer error so the control plane never carries absolute paths.
    nonisolated private static func redactMessage(_ message: String) -> String {
        let bounded = String(message.prefix(200))
        return bounded.replacingOccurrences(
            of: #"/[^\s/]+"#,
            with: "<sanitized>",
            options: .regularExpression
        )
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

    /// Bounded Steam client-state label for the control-plane snapshot.
    private func steamClientStateLabel(_ s: SteamClientState) -> String {
        switch s {
        case .stopped: return "stopped"
        case .launching: return "launching"
        case .runningVisible: return "runningVisible"
        case .runningHidden: return "runningHidden"
        case .stale: return "stale"
        case .stopping: return "stopping"
        case .recoveryRequired: return "recoveryRequired"
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
