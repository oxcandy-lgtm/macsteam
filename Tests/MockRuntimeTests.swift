// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct MockRuntimeTests {

    @Test func mockInspectionReturnsConfiguredValues() async {
        let inspection = RuntimeInspection(
            id: "mock",
            displayName: "Mock Runtime",
            version: "2.0",
            bundleURL: URL(fileURLWithPath: "/Applications/Mock.app"),
            isValid: true,
            failure: nil
        )
        let runtime = MockRuntime(inspection: inspection)

        let result = await runtime.inspect()
        #expect(result.id == "mock")
        #expect(result.isValid == true)
        #expect(result.version == "2.0")
    }

    @Test func mockGameInspectionReturnsConfiguredValues() async {
        let gameInspection = GameInspection(
            recipeID: "testgame",
            steamPresent: true,
            isWindowsSteam: true,
            manifestPresent: true,
            installDirectoryResolved: true,
            executablePresent: false,
            isReady: false
        )
        let runtime = MockRuntime(gameInspection: gameInspection)
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "testgame",
            displayName: "Test Game",
            store: GameRecipe.StoreInfo(type: .steam, appId: "99999"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "mock"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "test.acf")
        )

        let result = await runtime.inspectGame(recipe)
        #expect(result.recipeID == "testgame")
        #expect(result.executablePresent == false)
        #expect(result.isReady == false)
    }

    @Test func mockLaunchThrowsWhenConfigured() async {
        let runtime = MockRuntime()
        runtime.shouldThrowOnLaunch = true
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "test",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: "0"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "mock"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "test.acf")
        )

        await #expect(throws: LauncherFailure.self) {
            try await runtime.launchGame(recipe)
        }
    }

    @Test func mockSuccessDoesNotThrow() async throws {
        let runtime = MockRuntime()
        runtime.shouldThrowOnLaunch = false
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "test",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: "0"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "mock"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "test.acf")
        )

        try await runtime.launchGame(recipe)
    }
}
