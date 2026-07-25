// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A fully mocked runtime for testing UI and state transitions without
/// a real CrossOver installation.
///
/// Configure behaviour by setting properties before calling methods.
final class MockRuntime: CompatibilityRuntime, @unchecked Sendable {
    let id = "mock"

    var simulatedInspection: RuntimeInspection
    var simulatedGameInspection: GameInspection
    var shouldThrowOnLaunch = false
    var shouldThrowOnOpenStore = false

    // Call tracking for tests
    var didCallLaunch = false
    var didCallOpenStore = false
    var didCallInspect = false
    var didCallInspectGame = false

    init(
        inspection: RuntimeInspection? = nil,
        gameInspection: GameInspection? = nil
    ) {
        self.simulatedInspection = inspection ?? RuntimeInspection(
            id: "mock",
            displayName: "Mock Runtime",
            version: "1.0.0",
            bundleURL: URL(fileURLWithPath: "/Applications/Mock.app"),
            isValid: true,
            failure: nil
        )
        self.simulatedGameInspection = gameInspection ?? GameInspection(
            recipeID: "cloverpit",
            steamPresent: true,
            isWindowsSteam: true,
            manifestPresent: true,
            installDirectoryResolved: true,
            executablePresent: true,
            isReady: true
        )
    }

    func inspect() async -> RuntimeInspection {
        didCallInspect = true
        return simulatedInspection
    }

    func inspectGame(_ recipe: GameRecipe) async -> GameInspection {
        didCallInspectGame = true
        return simulatedGameInspection
    }

    func openStore(for recipe: GameRecipe) async throws {
        didCallOpenStore = true
        if shouldThrowOnOpenStore {
            throw LauncherFailure.processStartFailed(underlying: "Mock store error")
        }
        // no-op in mock
    }

    func launchGame(_ recipe: GameRecipe) async throws {
        didCallLaunch = true
        if shouldThrowOnLaunch {
            throw LauncherFailure.processStartFailed(underlying: "Mock launch error")
        }
        // no-op in mock
    }
}
