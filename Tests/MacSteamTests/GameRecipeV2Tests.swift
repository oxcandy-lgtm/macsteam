// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct GameRecipeTests {

    // MARK: - Helpers

    private func validRecipeJSON() -> Data {
        let json = """
        {
            "schemaVersion": 2,
            "id": "cloverpit",
            "displayName": "CloverPit",
            "store": { "type": "steam", "appId": "3314790" },
            "runtime": {
                "requiredCapabilities": ["windowsProcess"],
                "preferredRuntime": "managed-wine",
                "fallbackRuntimes": ["imported-wine"]
            },
            "graphics": {
                "preferred": "dxvk",
                "fallback": ["wined3d"]
            },
            "prefix": {
                "id": "cloverpit",
                "windowsVersion": "win10",
                "isolation": "per-game"
            },
            "storeInstallation": {
                "installerMode": "automatic",
                "installerProduct": "steam",
                "redistribution": "forbidden"
            },
            "launch": {
                "storeArguments": ["-applaunch", "3314790"]
            },
            "detection": {
                "manifestName": "appmanifest_3314790.acf",
                "executableCandidates": ["CloverPit.exe"]
            },
            "savePolicy": {
                "mode": "discover-only",
                "backupBeforeDestructiveRepair": false
            }
        }
        """
        return json.data(using: .utf8)!
    }

    private func makeValidRecipe() -> GameRecipe {
        GameRecipe(
            schemaVersion: 2,
            id: "cloverpit",
            displayName: "CloverPit",
            store: GameRecipe.StoreInfo(type: .steam, appId: "3314790"),
            runtime: GameRecipe.RuntimeRequirements(
                requiredCapabilities: ["windowsProcess"],
                preferredRuntime: .managedWine,
                fallbackRuntimes: [.importedWine]
            ),
            graphics: GameRecipe.GraphicsConfig(
                preferred: .dxvk,
                fallback: [.wined3d]
            ),
            prefix: GameRecipe.PrefixConfig(
                id: "cloverpit",
                windowsVersion: .win10,
                isolation: .perGame
            ),
            storeInstallation: GameRecipe.StoreInstallationConfig(
                installerMode: .automatic,
                installerProduct: "steam",
                redistribution: .forbidden
            ),
            launch: GameRecipe.LaunchConfig(
                storeArguments: ["-applaunch", "3314790"]
            ),
            detection: GameRecipe.DetectionConfig(
                manifestName: "appmanifest_3314790.acf",
                executableCandidates: ["CloverPit.exe"]
            ),
            savePolicy: GameRecipe.SavePolicyConfig(
                mode: .discoverOnly,
                backupBeforeDestructiveRepair: false
            )
        )
    }

    // MARK: - Tests

    @Test func testValidRecipePassesValidation() throws {
        let jsonData = validRecipeJSON()
        let recipe = try JSONDecoder().decode(GameRecipe.self, from: jsonData)
        #expect(recipe.schemaVersion == 2)
        #expect(recipe.isValid)
        #expect(recipe.displayName == "CloverPit")
        #expect(recipe.detection.executableCandidates == ["CloverPit.exe"])
    }

    @Test func testRejectsUnknownSchemaVersion() {
        let recipe = makeValidRecipe()
        let invalid = GameRecipe(
            schemaVersion: 3,
            id: recipe.id,
            displayName: recipe.displayName,
            store: recipe.store,
            runtime: recipe.runtime,
            graphics: recipe.graphics,
            prefix: recipe.prefix,
            storeInstallation: recipe.storeInstallation,
            launch: recipe.launch,
            detection: recipe.detection,
            savePolicy: recipe.savePolicy
        )
        #expect(!invalid.isValid)
    }

    @Test func testRejectsEmptyDisplayName() {
        let recipe = makeValidRecipe()
        let invalid = GameRecipe(
            schemaVersion: recipe.schemaVersion,
            id: recipe.id,
            displayName: "",
            store: recipe.store,
            runtime: recipe.runtime,
            graphics: recipe.graphics,
            prefix: recipe.prefix,
            storeInstallation: recipe.storeInstallation,
            launch: recipe.launch,
            detection: recipe.detection,
            savePolicy: recipe.savePolicy
        )
        #expect(!invalid.isValid)
    }

    @Test func testRejectsMissingExecutables() {
        let recipe = makeValidRecipe()
        let invalid = GameRecipe(
            schemaVersion: recipe.schemaVersion,
            id: recipe.id,
            displayName: recipe.displayName,
            store: recipe.store,
            runtime: recipe.runtime,
            graphics: recipe.graphics,
            prefix: recipe.prefix,
            storeInstallation: recipe.storeInstallation,
            launch: recipe.launch,
            detection: GameRecipe.DetectionConfig(
                manifestName: "appmanifest_3314790.acf",
                executableCandidates: []
            ),
            savePolicy: recipe.savePolicy
        )
        #expect(!invalid.isValid)
    }
}
