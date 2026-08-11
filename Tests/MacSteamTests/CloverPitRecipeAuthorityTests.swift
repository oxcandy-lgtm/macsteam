// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct CloverPitRecipeAuthorityTests {

    // MARK: - Packaged recipe (production default loader path)

    @Test
    func packagedRecipeLoadsThroughDefaultLoader() throws {
        let packaged = try RecipeLoader().loadRecipe(named: "cloverpit")

        #expect(packaged.id == "cloverpit")
        #expect(packaged.schemaVersion == 2)
        #expect(packaged.isValid)
    }

    @Test
    func packagedRecipeExactlyEqualsCanonicalAuthority() throws {
        let packaged = try RecipeLoader().loadRecipe(named: "cloverpit")

        // Full equality including array order across every field.
        #expect(packaged == CloverPitRecipeAuthority.canonical)
    }

    @Test
    func missingPackagedRecipeFailsClosed() {
        #expect(throws: RecipeLoader.LoaderError.self) {
            try RecipeLoader().loadRecipe(named: "definitely-missing-u1r18-r8-fix1")
        }
    }

    @Test
    func injectedBaseURLRegressionProof() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("u1r18-r8-fix1-injected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let minimalJSON = """
        {
          "schemaVersion": 2,
          "id": "injected-proof",
          "displayName": "Injected Proof",
          "store": { "type": "steam", "appId": "1" },
          "runtime": {
            "requiredCapabilities": ["isolated-prefix"],
            "preferredRuntime": "imported-wine",
            "fallbackRuntimes": []
          },
          "graphics": { "preferred": "wined3d", "fallback": [] },
          "prefix": { "id": "injected", "windowsVersion": "win10", "isolation": "per-game" },
          "storeInstallation": {
            "installerMode": "user-selected-file",
            "installerProduct": "steam-client",
            "redistribution": "forbidden"
          },
          "launch": { "storeArguments": ["-applaunch", "1"] },
          "detection": { "manifestName": "appmanifest_1.acf", "executableCandidates": ["Game.exe"] },
          "savePolicy": { "mode": "discover-only", "backupBeforeDestructiveRepair": true }
        }
        """

        try minimalJSON.write(to: tempDir.appendingPathComponent("injected-proof.json"),
                              atomically: true, encoding: .utf8)

        let loader = RecipeLoader(baseURL: tempDir)
        let recipe = try loader.loadRecipe(named: "injected-proof")
        #expect(recipe.id == "injected-proof")
        #expect(recipe.schemaVersion == 2)
        #expect(recipe.isValid)
    }

    // MARK: - Canonical authority semantics

    @Test
    func canonicalRecipeUsesImportedWine() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.runtime.preferredRuntime == .importedWine)
    }

    @Test
    func canonicalRecipeFallbackIsExactlySystemWine() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.runtime.fallbackRuntimes == [.systemWine])
    }

    @Test
    func canonicalRecipeDoesNotReferenceCrossOver() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.runtime.preferredRuntime != .crossover)
        #expect(!recipe.runtime.fallbackRuntimes.contains(.crossover))
        #expect(!recipe.runtime.requiredCapabilities.contains("commercial"))
    }

    @Test
    func canonicalRecipeUsesWineD3D() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.graphics.preferred == .wined3d)
    }

    @Test
    func canonicalRecipeUsesUserSelectedSteamClientInstaller() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.storeInstallation.installerMode == .userSelectedFile)
        #expect(recipe.storeInstallation.installerProduct == "steam-client")
        #expect(recipe.storeInstallation.redistribution == .forbidden)
    }

    @Test
    func canonicalRecipeRequiresThreeExactCapabilities() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(
            recipe.runtime.requiredCapabilities
                == ["windows-process", "steam-client", "isolated-prefix"]
        )
    }

    @Test
    func canonicalRecipeRequiresBackupBeforeDestructiveRepair() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.savePolicy.mode == .discoverOnly)
        #expect(recipe.savePolicy.backupBeforeDestructiveRepair == true)
    }

    @Test
    func canonicalRecipeIsSchemaValid() {
        let recipe = CloverPitRecipeAuthority.canonical
        #expect(recipe.isValid)
        #expect(recipe.schemaVersion == 2)
        #expect(recipe.launch.storeArguments == ["-applaunch", "3314790"])
        #expect(recipe.detection.manifestName == "appmanifest_3314790.acf")
        #expect(recipe.detection.executableCandidates == ["CloverPit.exe"])
    }
}