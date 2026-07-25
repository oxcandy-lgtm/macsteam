// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct GameManagerTests {

    /// Create a RecipeLoader that reads from a temp directory with a valid cloverpit recipe.
    private func makeRecipeLoader() -> RecipeLoader {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
            "schemaVersion": 1,
            "id": "cloverpit",
            "displayName": "CloverPit",
            "store": { "type": "steam", "appId": "3314790" },
            "runtime": { "preferredAdapter": "crossover" },
            "launch": { "arguments": ["-applaunch", "3314790"] },
            "detection": { "manifestName": "appmanifest_3314790.acf" }
        }
        """
        try! json.write(to: dir.appendingPathComponent("cloverpit.json"), atomically: true, encoding: .utf8)
        return RecipeLoader(baseURL: dir)
    }

    @MainActor
    @Test func initialStateIsInspecting() {
        let manager = GameManager()
        #expect(manager.state == LauncherState.inspecting)
    }

    @MainActor
    @Test func inspectWithMockRuntimeReachesReady() async {
        let recipeLoader = makeRecipeLoader()
        let mockRuntime = MockRuntime()
        let locator = RuntimeLocatorMock(returns: mockRuntime)
        let detector = SteamDetectorMock(result: .windowsSteamFound(
            URL(fileURLWithPath: "/mock/steam.exe")
        ))

        let manager = GameManager(
            recipeLoader: recipeLoader,
            runtimeLocator: locator,
            steamDetector: detector
        )

        await manager.inspect()
        #expect(manager.state == LauncherState.ready)
    }

    @MainActor
    @Test func inspectWithMissingRuntimeShowsMissing() async {
        let recipeLoader = makeRecipeLoader()
        let locator = RuntimeLocatorMock(returns: nil)
        let manager = GameManager(
            recipeLoader: recipeLoader,
            runtimeLocator: locator
        )

        await manager.inspect()
        #expect(manager.state == LauncherState.runtimeMissing)
    }

    @MainActor
    @Test func launchWhenReadyWorks() async {
        let recipeLoader = makeRecipeLoader()
        let mockRuntime = MockRuntime()
        let locator = RuntimeLocatorMock(returns: mockRuntime)
        let detector = SteamDetectorMock(result: .windowsSteamFound(
            URL(fileURLWithPath: "/mock/steam.exe")
        ))

        let manager = GameManager(
            recipeLoader: recipeLoader,
            runtimeLocator: locator,
            steamDetector: detector
        )

        await manager.inspect()
        #expect(manager.state == LauncherState.ready)

        await manager.launch()
        #expect(mockRuntime.didCallLaunch)
    }

    @MainActor
    @Test func launchFailsWhenRuntimeReportsError() async {
        let recipeLoader = makeRecipeLoader()
        let mockRuntime = MockRuntime()
        mockRuntime.shouldThrowOnLaunch = true
        let locator = RuntimeLocatorMock(returns: mockRuntime)
        let detector = SteamDetectorMock(result: .windowsSteamFound(
            URL(fileURLWithPath: "/mock/steam.exe")
        ))

        let manager = GameManager(
            recipeLoader: recipeLoader,
            runtimeLocator: locator,
            steamDetector: detector
        )

        await manager.inspect()
        #expect(manager.state == LauncherState.ready)

        await manager.launch()
        if case LauncherState.failed = manager.state {
            #expect(Bool(true))
        } else {
            Issue.record("Expected failed state, got \(manager.state)")
        }
    }

    @MainActor
    @Test func stateMachinePreventsLaunchWhenNotReady() async {
        let manager = GameManager()

        await manager.launch()
        #expect(manager.state == LauncherState.inspecting)
    }

    @MainActor
    @Test func detectNativeMacSteamOnly() async {
        let recipeLoader = makeRecipeLoader()
        let mockRuntime = MockRuntime()
        let locator = RuntimeLocatorMock(returns: mockRuntime)
        let detector = SteamDetectorMock(result: .nativeMacSteamOnly)

        let manager = GameManager(
            recipeLoader: recipeLoader,
            runtimeLocator: locator,
            steamDetector: detector
        )

        await manager.inspect()
        #expect(manager.state == LauncherState.storeMissing)
    }

    @MainActor
    @Test func inspectReachesGameNotInstalled() async {
        let recipeLoader = makeRecipeLoader()
        let mockRuntime = MockRuntime()
        mockRuntime.simulatedGameInspection = GameInspection(
            recipeID: "cloverpit",
            steamPresent: true,
            isWindowsSteam: true,
            manifestPresent: false,
            installDirectoryResolved: false,
            executablePresent: false,
            isReady: false
        )
        let locator = RuntimeLocatorMock(returns: mockRuntime)
        let detector = SteamDetectorMock(result: .windowsSteamFound(
            URL(fileURLWithPath: "/mock/steam.exe")
        ))

        let manager = GameManager(
            recipeLoader: recipeLoader,
            runtimeLocator: locator,
            steamDetector: detector
        )

        await manager.inspect()
        #expect(manager.state == LauncherState.gameNotInstalled)
    }
}

// MARK: - Mocks for testing

final class RuntimeLocatorMock: RuntimeLocator, @unchecked Sendable {
    private let runtime: (any CompatibilityRuntime)?

    init(returns runtime: (any CompatibilityRuntime)?) {
        self.runtime = runtime
        super.init()
    }

    override func locatePreferredRuntime() -> (any CompatibilityRuntime)? {
        runtime
    }
}

final class SteamDetectorMock: SteamDetector, @unchecked Sendable {
    private let detectionResult: SteamDetectionResult

    init(result: SteamDetectionResult) {
        self.detectionResult = result
        super.init()
    }

    override func detectWindowsSteam(in runtime: any CompatibilityRuntime) -> SteamDetectionResult {
        detectionResult
    }
}
