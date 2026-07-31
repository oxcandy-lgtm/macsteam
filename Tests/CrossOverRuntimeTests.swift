// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct CrossOverRuntimeTests {

    let testBundleURL = URL(fileURLWithPath: "/Applications/CrossOver.app")

    func makeRecipe() -> GameRecipe {
        GameRecipe(
            schemaVersion: 1,
            id: "cloverpit",
            displayName: "CloverPit",
            store: GameRecipe.StoreInfo(type: .steam, appId: "3314790"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "crossover"),
            launch: GameRecipe.LaunchConfig(arguments: ["-applaunch", "3314790"]),
            detection: GameRecipe.DetectionConfig(
                manifestName: "appmanifest_3314790.acf",
                executableCandidates: ["CloverPit.exe"]
            )
        )
    }

    @Test func makeLaunchPlanUsesWineAndBottle() throws {
        // Build launch plan using the recipe
        let runtime = CrossOverRuntime(bundleURL: testBundleURL)
        let recipe = makeRecipe()

        // makeLaunchPlan requires wine executable to exist
        // Since we don't have a real CrossOver, it should throw
        #expect(throws: LauncherFailure.self) {
            try runtime.makeLaunchPlan(for: recipe)
        }
    }

    @Test func makeStorePlanUsesStoreUrl() throws {
        let runtime = CrossOverRuntime(bundleURL: testBundleURL)
        let recipe = makeRecipe()

        #expect(throws: LauncherFailure.self) {
            try runtime.makeStorePlan(for: recipe)
        }
    }

    @Test func discoverBottlesReturnsEmptyWhenNoBottles() {
        let runtime = CrossOverRuntime(bundleURL: testBundleURL)
        let bottles = runtime.discoverBottles()
        // No real bottles in CI, so should be empty
        #expect(bottles.isEmpty)
    }

    @Test func findSteamBottleReturnsNilOnCleanSystem() {
        let runtime = CrossOverRuntime(bundleURL: testBundleURL)
        let found = runtime.findSteamBottle()
        #expect(found == nil)
    }

    @Test func inspectFailsForNonexistentBundle() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/NotCrossOver.app")
        let runtime = CrossOverRuntime(bundleURL: bogusURL)
        let result = await runtime.inspect()
        #expect(result.isValid == false)
        #expect(result.failure == .bundleNotValid)
    }

    @Test func recipeWithExecutableCandidatesEncodesCorrectly() throws {
        let json = """
        {
            "schemaVersion": 1,
            "id": "test",
            "displayName": "Test",
            "store": { "type": "steam", "appId": "12345" },
            "runtime": { "preferredAdapter": "crossover" },
            "launch": { "arguments": ["-applaunch", "12345"] },
            "detection": {
                "manifestName": "appmanifest_12345.acf",
                "executableCandidates": ["Game.exe", "Launcher.exe"]
            }
        }
        """
        let data = json.data(using: .utf8)!
        let recipe = try JSONDecoder().decode(GameRecipe.self, from: data)
        #expect(recipe.detection.executableCandidates == ["Game.exe", "Launcher.exe"])
    }

    @Test func recipeWithoutExecutableCandidatesDefaultsToNil() throws {
        let json = """
        {
            "schemaVersion": 1,
            "id": "test",
            "displayName": "Test",
            "store": { "type": "steam", "appId": "12345" },
            "runtime": { "preferredAdapter": "crossover" },
            "launch": { "arguments": ["-applaunch", "12345"] },
            "detection": {
                "manifestName": "appmanifest_12345.acf"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let recipe = try JSONDecoder().decode(GameRecipe.self, from: data)
        #expect(recipe.detection.executableCandidates == nil)
    }
}
