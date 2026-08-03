// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct CloverPitRecipeAuthorityTests {

    /// The source-directory recipe (the exact byte stream that SwiftPM copies
    /// into the bundle as `Recipes/cloverpit.json`). The default
    /// `RecipeLoader()` search is under `Resources/Recipes/`, which does not
    /// match the packaged layout, so we inject the canonical source dir.
    private var bundledRecipesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacSteam/Resources/Recipes")
    }

    private func loadBundledRecipe() throws -> GameRecipe {
        try RecipeLoader(baseURL: bundledRecipesURL).loadRecipe(named: "cloverpit")
    }

    @Test
    func bundledRecipeLoadsSuccessfully() throws {
        let bundled = try loadBundledRecipe()
        #expect(bundled.id == "cloverpit")
        #expect(bundled.schemaVersion == 2)
        #expect(bundled.isValid)
    }

    @Test
    func bundledRecipeExactlyEqualsCanonicalAuthority() throws {
        let bundled = try loadBundledRecipe()
        // Full equality including array order across every field.
        #expect(bundled == CloverPitRecipeAuthority.canonical)
    }

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