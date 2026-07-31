// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct GameRecipeTests {

    @Test func validRecipePassesValidation() throws {
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "cloverpit",
            displayName: "CloverPit",
            store: GameRecipe.StoreInfo(type: .steam, appId: "3314790"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "crossover"),
            launch: GameRecipe.LaunchConfig(arguments: ["-applaunch", "3314790"]),
            detection: GameRecipe.DetectionConfig(manifestName: "appmanifest_3314790.acf")
        )
        #expect(throws: Never.self) { try recipe.validate() }
    }

    @Test func rejectsUnknownSchemaVersion() {
        let recipe = GameRecipe(
            schemaVersion: 42,
            id: "test",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: "12345"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "crossover"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "test.acf")
        )
        #expect(throws: RecipeValidationError.unknownSchemaVersion(42)) {
            try recipe.validate()
        }
    }

    @Test func rejectsEmptyAppID() {
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "test",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: ""),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "crossover"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "test.acf")
        )
        #expect(throws: RecipeValidationError.emptyAppID) {
            try recipe.validate()
        }
    }

    @Test func rejectsEmptyID() {
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: "12345"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "crossover"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "test.acf")
        )
        #expect(throws: RecipeValidationError.self) {
            try recipe.validate()
        }
    }
}
