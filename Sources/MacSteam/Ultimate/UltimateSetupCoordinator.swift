// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Coordinates the full Ultimate U1 setup flow: runtime → prefix → Steam → CloverPit.
///
/// All state lives here; individual views observe a single coordinator instance
/// through `@Bindable`.
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
    private let sessionSupervisor = GameSessionSupervisor()
    private let prefixManager = PrefixManager()
    private let steamDetector = SteamInstallationDetector()
    private let launchCoordinator = SteamLaunchCoordinator()

    private var activeRuntime: (any CompatibilityRuntime)?
    private var runtimeURL: URL?

    /// Canonical prefix layout resolved by PrefixManager (single source of truth).
    private var prefixLayout: PrefixLayout?

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

    /// Generate a fresh 5-digit installer session ID.
    func generateInstallerID() {
        installerID = String(format: "%05d", Int.random(in: 10000...99999))
        log("Installer session: #\(installerID)")
    }

    // MARK: - Init

    init() {
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
    }

    // MARK: - Flow

    /// Step 1: Inspect the system for available Wine runtimes using RuntimeRegistry.
    func inspectSystem() async {
        state = .inspecting
        error = nil

        log("Inspecting system for Wine runtimes…")
        let candidates = await runtimeRegistry.discover()
        guard let preferred = runtimeRegistry.selectPreferred(from: candidates)
        else {
            state = .runtimeRequired
            error = .runtimeNotFound
            log("No Wine runtime found")
            return
        }

        selectCandidate(preferred)
        log("Runtime selected: \(preferred.displayName) v\(preferred.inspection?.version ?? "?")")
        generateInstallerID()
    }

    /// Apply a selected candidate as the active runtime.
    private func selectCandidate(_ candidate: RuntimeCandidate) {
        self.runtimeInspection = candidate.inspection
        self.activeRuntime = candidate.runtime
        self.runtimeURL = candidate.url

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

        selectCandidate(candidate)
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
            let layout: PrefixLayout
            if let existing = try? prefixManager.validatedLayout(for: recipe) {
                layout = existing
                self.prefixLayout = layout
                log("Canonical prefix resolved")
                log("Prefix signature: drive_c=\(layout.signature().driveCDirectory ? "present" : "missing")")

                // Check if Steam is already installed
                log("Checking steam.exe in canonical prefix…")
                if layout.signature().steamExePresent {
                    state = .steamReady
                    log("steam.exe FOUND in canonical prefix — advancing to Steam ready")
                    return
                }
                log("steam.exe NOT FOUND — proceeding with wineboot")
            } else {
                // Create new prefix root directory (wineboot will do the rest)
                let rootURL = prefixManager.prefixURL(for: recipe)
                try prefixManager.createPrefix(for: recipe)
                log("Prefix root created at: \(rootURL.path)")
                // Construct layout from validated root (root exists, wineboot hasn't run yet)
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

            // Inspect prefix
            let inspector = PrefixInspector()
            self.prefixInspection = inspector.inspect(url: prefixDir)

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
    func installSteam() async {
        state = .steamInstallationPending
        error = nil

        guard let installer = selectedInstaller,
              let runtime = activeRuntime,
              let runtimeURL = runtimeURL else {
            error = .steamInstallationFailed("No installer or runtime selected")
            state = .steamInstallerRequired
            return
        }

        let wineURL: URL
        if runtime is SystemWineRuntime {
            wineURL = runtimeURL.appendingPathComponent("wine")
        } else if runtime is ImportedWineRuntime {
            wineURL = runtimeURL.appendingPathComponent("bin/wine")
        } else {
            error = .runtimeInspectionFailed("Unknown runtime type")
            state = .runtimeInvalid
            return
        }

        do {
            // Launch SteamSetup.exe with wine
            let result = try await processRunner.run(
                executable: wineURL,
                arguments: [installer.fileURL.path],
                environment: [
                    "WINEPREFIX": prefixLayout?.root.path ?? "",
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                timeout: nil, // no timeout — user installs interactively
                mode: .detached
            )

            // After installer completes, check for Steam installation
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3s grace
            let inspection = inspectSteamInstallation()
            self.steamInspection = inspection

            if inspection.steamInstalled {
                state = .steamReady
            } else {
                // User might still be installing — stay in pending
                state = .steamInstallationPending
            }
        } catch {
            self.error = .steamInstallationFailed(error.localizedDescription)
            state = .steamInstallerVerified
        }
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

    /// Step 6b: Launch Windows Steam UI (no game args) for user to install CloverPit.
    /// NX Dispatch §4 — dedicated method, never calls launchCloverPit().
    func launchWindowsSteam() async {
        state = .launching
        error = nil

        guard let runtime = activeRuntime,
              let runtimeURL = runtimeURL,
              let runtimeControl = runtime as? WineRuntimeControl
        else {
            error = .launchFailed("No runtime selected or runtime lacks WineRuntimeControl")
            state = .steamReady
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

        log("Launching Windows Steam via System Wine (no game args)…")

        do {
            let plan = LaunchPlan(
                runtimeExecutable: wineURL,
                arguments: [steamExe.path] + steamUIRenderProfile.launchArguments,
                mode: .detached,
                environment: [
                    "WINEPREFIX": prefixLayout?.root.path ?? "",
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                workingDirectory: prefixLayout?.root ?? URL(fileURLWithPath: "/")
            )

            log("Windows Steam session started: purpose=steamClient, profile=\(steamUIRenderProfile.rawValue)")
            state = .steamInstallationPending

            let _ = try await sessionSupervisor.launch(
                plan: plan,
                runtimeControl: runtimeControl,
                prefixRoot: prefixLayout?.root ?? URL(fileURLWithPath: "/"),
                recipeID: recipe.id,
                runtimeID: runtimeSourceType ?? "unknown",
                purpose: .steamSetup
            )
        } catch {
            self.error = .launchFailed(error.localizedDescription)
            state = .steamReady
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
            let plan = LaunchPlan(
                runtimeExecutable: wineURL,
                arguments: [steamExe.path]
                    + steamUIRenderProfile.launchArguments
                    + ["-applaunch", "3314790", "-popupwindow", "-screen-fullscreen", "0"],
                mode: .detached,
                environment: [
                    "WINEPREFIX": prefixLayout?.root.path ?? "",
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                workingDirectory: prefixLayout?.root ?? URL(fileURLWithPath: "/")
            )

            let session = try await sessionSupervisor.launch(
                plan: plan,
                runtimeControl: runtimeControl,
                prefixRoot: prefixLayout?.root ?? URL(fileURLWithPath: "/"),
                recipeID: recipe.id,
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

    /// Stop the active game session.
    func stopSession() async {
        try? await sessionSupervisor.stop()
    }

    /// Whether a Steam setup session is active.
    var hasActiveSteamSetupSession: Bool {
        sessionSupervisor.activeSession?.purpose == .steamSetup
        && sessionSupervisor.isRunning
    }

    /// Stop Steam setup session for app termination.
    /// Returns true if stopped or no session; false if stop failed.
    func stopSteamSetupForTermination() async -> Bool {
        guard hasActiveSteamSetupSession else { return true }
        do {
            try await sessionSupervisor.stop()
            return true
        } catch {
            log("Failed to stop Steam setup session on termination: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop steam setup session if active (for back/next/close transitions).
    func stopSteamSetupSessionIfNeeded() async throws {
        guard hasActiveSteamSetupSession else { return }
        try await sessionSupervisor.stop()
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

    // MARK: - Private

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
