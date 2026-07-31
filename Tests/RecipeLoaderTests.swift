// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RecipeLoaderTests {

    let loader = RecipeLoader()

    /// Write a minimal valid recipe to a temp file for testing.
    private func writeRecipeJSON(_ json: String, name: String = "test.json") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func loadValidRecipe() throws {
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
        let url = writeRecipeJSON(json, name: "cloverpit_test.json")
        defer { try? FileManager.default.removeItem(at: url) }

        let recipe = try loader.loadRecipe(from: url)
        #expect(recipe.id == "cloverpit")
        #expect(recipe.displayName == "CloverPit")
        #expect(recipe.store.type == .steam)
        #expect(recipe.store.appId == "3314790")
        #expect(recipe.schemaVersion == 1)
        #expect(recipe.launch.arguments == ["-applaunch", "3314790"])
        #expect(recipe.detection.manifestName == "appmanifest_3314790.acf")
    }

    @Test func rejectInvalidJSON() throws {
        let url = writeRecipeJSON("not json", name: "bad.json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RecipeLoader.LoaderError.invalidData) {
            try loader.loadRecipe(from: url)
        }
    }

    @Test func rejectUnknownSchemaVersion() throws {
        let json = """
        {
            "schemaVersion": 99,
            "id": "test",
            "displayName": "Test",
            "store": { "type": "steam", "appId": "12345" },
            "runtime": { "preferredAdapter": "crossover" },
            "launch": { "arguments": [] },
            "detection": { "manifestName": "test.acf" }
        }
        """
        let url = writeRecipeJSON(json, name: "schema99.json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RecipeLoader.LoaderError.validationFailed(.unknownSchemaVersion(99))) {
            try loader.loadRecipe(from: url)
        }
    }

    @Test func rejectEmptyAppID() throws {
        let json = """
        {
            "schemaVersion": 1,
            "id": "test",
            "displayName": "Test",
            "store": { "type": "steam", "appId": "" },
            "runtime": { "preferredAdapter": "crossover" },
            "launch": { "arguments": [] },
            "detection": { "manifestName": "test.acf" }
        }
        """
        let url = writeRecipeJSON(json, name: "emptyid.json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RecipeLoader.LoaderError.validationFailed(.emptyAppID)) {
            try loader.loadRecipe(from: url)
        }
    }

    @Test func rejectAbsolutePathInRecipe() throws {
        let json = """
        {
            "schemaVersion": 1,
            "id": "/Users/example/recipe",
            "displayName": "Evil",
            "store": { "type": "steam", "appId": "12345" },
            "runtime": { "preferredAdapter": "crossover" },
            "launch": { "arguments": [] },
            "detection": { "manifestName": "test.acf" }
        }
        """
        let url = writeRecipeJSON(json, name: "abspath.json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try loader.loadRecipe(from: url)
        }
    }
}
