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
    let runtimeLocator: RuntimeLocator
    private let steamDetector: SteamDetector
    private let processRunner: ProcessRunner
    private let diagnosticsStore: DiagnosticsStore

    // MARK: - Internal state

    private var activeRuntime: (any CompatibilityRuntime)?
    private var currentGameInspection: GameInspection?

    // MARK: - Init

    init(
        recipeLoader: RecipeLoader = RecipeLoader(),
        runtimeLocator: RuntimeLocator = RuntimeLocator(),
        steamDetector: SteamDetector = SteamDetector(),
        processRunner: ProcessRunner = ProcessRunner(),
        diagnosticsStore: DiagnosticsStore = DiagnosticsStore()
    ) {
        self.recipeLoader = recipeLoader
        self.runtimeLocator = runtimeLocator
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

        // 2. Locate runtime
        guard let runtime = runtimeLocator.locatePreferredRuntime() else {
            log("No compatible runtime found")
            state = .runtimeMissing
            return
        }

        let inspection = runtime.inspect()
        guard inspection.isUsable else {
            let fail = inspection.failures.first ?? RuntimeFailure(code: .bundleNotValid, message: "Runtime unusable")
            log("Runtime invalid: \(fail.message)")
            state = .runtimeInvalid(fail)
            return
        }

        activeRuntime = runtime
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
        return await inspector.inspect(recipe: recipe, runtime: runtime)
    }

    private func log(_ message: String) {
        diagnosticsStore.append(message)
    }
}

// MARK: - Supporting types

/// Snapshot of a game's installation state within a runtime.
struct GameInspection: Equatable, Sendable {
    let recipeID: String
    let steamPresent: Bool
    let isWindowsSteam: Bool
    let manifestPresent: Bool
    let installDirectoryResolved: Bool
    let executablePresent: Bool
    let isReady: Bool
}

