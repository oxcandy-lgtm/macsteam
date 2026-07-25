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

        let inspection = await runtime.inspect()
        guard inspection.isValid else {
            log("Runtime invalid: \(inspection.failure?.localizedDescription ?? "unknown")")
            state = .runtimeInvalid(inspection.failure ?? .bundleNotValid)
            return
        }

        activeRuntime = runtime
        log("Runtime found: \(inspection.displayName) v\(inspection.version ?? "?")")

        // 3. Detect Steam
        let steamResult = steamDetector.detectWindowsSteam(in: runtime)
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

        // 4. Inspect game
        let gameInspection = await runtime.inspectGame(recipe)
        currentGameInspection = gameInspection

        log("Game inspection: manifest=\(gameInspection.manifestPresent) installDir=\(gameInspection.installDirectoryResolved) executable=\(gameInspection.executablePresent)")

        guard gameInspection.isReady else {
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

        do {
            try await runtime.launchGame(recipe)
            // Detached launch: return to ready immediately after process spawn
            state = .ready
            log("Launch command submitted")
        } catch {
            log("Launch failed: \(error.localizedDescription)")
            state = .failed(.processStartFailed(underlying: error.localizedDescription))
        }
    }

    /// Open the store (e.g., Windows Steam) for the current recipe.
    /// Errors propagate to the UI.
    func openStore() async {
        guard let recipe = currentRecipe, let runtime = activeRuntime else { return }
        do {
            try await runtime.openStore(for: recipe)
            log("Store opened for \(recipe.displayName)")
        } catch {
            log("Failed to open store: \(error.localizedDescription)")
            state = .failed(.processStartFailed(underlying: error.localizedDescription))
        }
    }

    /// Open diagnostics screen data.
    func refreshDiagnostics() {
        lastDiagnostics = diagnosticsStore.recentEntries()
    }

    // MARK: - Helpers

    private func log(_ message: String) {
        diagnosticsStore.append(message)
    }
}
