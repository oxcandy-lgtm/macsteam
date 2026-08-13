// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Drives the launcher state machine and coordinates recipe loading,
/// runtime detection, Steam detection, and process execution.
///
/// GameManager is the central hub that the UI observes for state changes.
@MainActor
final class GameManager: ObservableObject, Sendable {

    // MARK: - Published state

    @Published private(set) var state: LauncherState = .inspecting
    @Published private(set) var currentRecipe: GameRecipe?
    @Published private(set) var lastDiagnostics: [DiagnosticEntry] = []

    // MARK: - Dependencies

    let recipeLoader: RecipeLoader
    let runtimeRegistry: RuntimeRegistry
    private let steamDetector: SteamDetector
    private let processRunner: ProcessRunner
    private let diagnosticsStore: DiagnosticsStore

    // MARK: - Internal state

    private var activeRuntime: (any CompatibilityRuntime)?
    private var activeCandidate: RuntimeCandidate?
    private var currentGameInspection: GameInspection?

    // MARK: - Init

    init(
        recipeLoader: RecipeLoader = RecipeLoader(),
        runtimeRegistry: RuntimeRegistry = RuntimeRegistry(),
        steamDetector: SteamDetector = SteamDetector(),
        processRunner: ProcessRunner = ProcessRunner(),
        diagnosticsStore: DiagnosticsStore = DiagnosticsStore()
    ) {
        self.recipeLoader = recipeLoader
        self.runtimeRegistry = runtimeRegistry
        self.steamDetector = steamDetector
        self.processRunner = processRunner
        self.diagnosticsStore = diagnosticsStore
    }

    // MARK: - Public API

    /// Perform full inspection from scratch.
    func inspect() async {
        state = .inspecting
        log("Starting inspection...")

        // 1. Load recipe
        let recipe: GameRecipe
        do {
            recipe = try recipeLoader.loadRecipe(named: "cloverpit")
            currentRecipe = recipe
            log("Recipe loaded: \(recipe.displayName)")
        } catch {
            log("Recipe loading failed: \(error.localizedDescription)")
            state = .failed(.processStartFailed(underlying: error.localizedDescription))
            return
        }

        // 2. Locate runtime via Registry (priority: Managed → Imported → System → CrossOver)
        let candidates = await runtimeRegistry.discover()
        guard let preferred = runtimeRegistry.selectPreferred(from: candidates) else {
            log("No compatible runtime found among \\(candidates.count) candidate(s)")
            state = .runtimeMissing
            return
        }

        guard let runtime = preferred.runtime else {
            log("Selected candidate has no runtime instance")
            state = .runtimeMissing
            return
        }

        let inspection = preferred.inspection ?? runtime.inspect()
        activeCandidate = preferred
        activeRuntime = runtime

        guard inspection.isUsable else {
            let fail = inspection.failures.first ?? RuntimeFailure(code: .bundleNotValid, message: "Runtime unusable")
            log("Runtime invalid: \(fail.message)")
            state = .runtimeInvalid(fail)
            return
        }

        log("Runtime found: \(inspection.displayName) v\(inspection.version ?? "?")")

        // 3. Detect Steam
        let steamResult = await steamDetector.detectWindowsSteam(in: runtime, recipe: recipe)
        switch steamResult {
        case .windowsSteamFound(let steamURL):
            log("Windows Steam found at \(PathRedactor.redactPath(steamURL.path))")
        case .nativeMacSteamOnly:
            log("Only native macOS Steam found")
            state = .storeMissing
            return
        case .noSteamFound:
            log("No Steam installation found in runtime")
            state = .storeMissing
            return
        }

        // 4. Check game installation via detection config
        let gameDetected = await checkGameInstallation(recipe: recipe, runtime: runtime)
        currentGameInspection = gameDetected

        guard gameDetected.isReady else {
            state = .gameNotInstalled
            return
        }

        state = .ready
        log("All checks passed. Ready to launch.")
    }

    /// Launch the current game.
    func launch() async {
        guard case .ready = state else { return }
        guard let recipe = currentRecipe, let runtime = activeRuntime else { return }

        state = .launching
        log("Launching \(recipe.displayName)...")

        guard let plan = runtime.launchPlan(for: recipe) else {
            log("No launch plan available")
            state = .failed(.processExecutableInvalid)
            return
        }

        // Validate boundary before executing
        if let boundary = plan.boundary {
            do {
                try boundary.validate(plan: plan)
            } catch {
                log("Boundary violation: \(error.localizedDescription)")
                state = .failed(.processStartFailed(underlying: "Boundary violation: \(error.localizedDescription)"))
                return
            }
        }

        do {
            _ = try await processRunner.run(
                executable: plan.runtimeExecutable,
                arguments: plan.arguments,
                mode: plan.mode
            )
            state = .ready
            log("Launch command submitted")
        } catch {
            log("Launch failed: \(error.localizedDescription)")
            state = .failed(.processStartFailed(underlying: error.localizedDescription))
        }
    }

    /// Open the store URL.
    func openStore() async {
        guard let recipe = currentRecipe else { return }
        let storeURL = URL(string: "https://store.steampowered.com/app/\(recipe.store.appId)")!
        log("Store URL: \(storeURL.absoluteString)")
        // User opens the URL via browser — MacSteam does not intercept
    }

    /// Open diagnostics screen data.
    func refreshDiagnostics() {
        lastDiagnostics = diagnosticsStore.recentEntries()
    }

    // MARK: - Helpers

    private func checkGameInstallation(recipe: GameRecipe, runtime: any CompatibilityRuntime) async -> GameInspection {
        // Check for Steam manifest and executables in the prefix
        let inspector = SteamInstallationDetector()
        // Legacy path — use PrefixManager to resolve canonical prefix
        let manager = PrefixManager()
        if let layout = try? manager.validatedLayout(for: recipe) {
            return await inspector.inspect(recipe: recipe, runtime: runtime, prefix: layout)
        }
        return .notReady(recipeID: recipe.id)
    }

    private func log(_ message: String) {
        diagnosticsStore.append(message)
    }
}

// MARK: - GameInstallState

/// NX Dispatch §6: Granular installation state.
///
/// Canonical installation state (CLOVERPIT-WINDOWS-INSTALL1 §1). Installation
/// truth is derived ONLY from the Wine-prefix Windows Steam library (Tier 1)
/// and its canonical downloading area (Tier 2). Non-canonical payloads (e.g. a
/// leftover SteamCMD staging area) are surfaced as `noncanonicalPayloadPresent`
/// and never influence readiness.
///
/// - `notInstalled`: No manifest, no files in the canonical Windows Steam library.
/// - `installRequested`: A canonical manifest exists, but no install directory is
///   resolved yet (Windows Steam has accepted the install).
/// - `downloading`: Files exist under the canonical Windows Steam downloading/ area.
/// - `installing`: Files are partially present in the canonical install directory.
/// - `verifying`: Canonical files present but not yet confirmed complete.
/// - `installed`: Fully installed in the canonical Windows Steam library (Tier 1).
/// - `blocked`: A canonical payload is present but cannot advance (inconsistent).
enum GameInstallState: String, Sendable, Equatable {
    case notInstalled
    case installRequested
    case downloading
    case installing
    case verifying
    case installed
    case blocked
}

// MARK: - Supporting types

/// Snapshot of a game's installation state within a runtime.
struct GameInspection: Equatable, Sendable {
    let recipeID: String
    let steamPresent: Bool
    let isWindowsSteam: Bool
    let manifestPresent: Bool
    let manifestAppID: String?
    let installdir: String?
    let installDirectoryResolved: Bool
    let executablePresent: Bool
    let executableName: String?
    let isReady: Bool
    let stateFlags: String?

    /// NX Dispatch §6: Granular install state.
    let installState: GameInstallState
    let canonicalInstallPresent: Bool
    let downloadPayloadPresent: Bool
    /// CLOVERPIT-WINDOWS-INSTALL1 §1: a non-canonical payload (e.g. SteamCMD
    /// staging leftovers) exists somewhere in the prefix but is NOT the
    /// canonical Windows Steam library. It must never set readiness.
    let noncanonicalPayloadPresent: Bool
    /// CLOVERPIT-WINDOWS-INSTALL1 §7: byte progress from the canonical
    /// manifest (`BytesDownloaded` / `BytesToDownload`). Nil when unknown.
    let bytesDownloaded: Int64?
    let bytesTotal: Int64?

    init(recipeID: String, steamPresent: Bool, isWindowsSteam: Bool,
         manifestPresent: Bool, manifestAppID: String? = nil,
         installdir: String? = nil,
         installDirectoryResolved: Bool, executablePresent: Bool,
         executableName: String? = nil, isReady: Bool,
         stateFlags: String? = nil,
         installState: GameInstallState = .notInstalled,
         canonicalInstallPresent: Bool = false,
         downloadPayloadPresent: Bool = false,
         noncanonicalPayloadPresent: Bool = false,
         bytesDownloaded: Int64? = nil,
         bytesTotal: Int64? = nil) {
        self.recipeID = recipeID
        self.steamPresent = steamPresent
        self.isWindowsSteam = isWindowsSteam
        self.manifestPresent = manifestPresent
        self.manifestAppID = manifestAppID
        self.installdir = installdir
        self.installDirectoryResolved = installDirectoryResolved
        self.executablePresent = executablePresent
        self.executableName = executableName
        self.isReady = isReady
        self.stateFlags = stateFlags
        self.installState = installState
        self.canonicalInstallPresent = canonicalInstallPresent
        self.downloadPayloadPresent = downloadPayloadPresent
        self.noncanonicalPayloadPresent = noncanonicalPayloadPresent
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    static func notReady(recipeID: String) -> GameInspection {
        GameInspection(recipeID: recipeID, steamPresent: false,
            isWindowsSteam: false, manifestPresent: false,
            installDirectoryResolved: false, executablePresent: false,
            isReady: false, installState: .notInstalled)
    }
}

