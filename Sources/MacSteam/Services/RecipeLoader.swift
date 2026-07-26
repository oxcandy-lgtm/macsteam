// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Loads and validates game recipe JSON files from the app bundle.
final class RecipeLoader: Sendable {

    /// Optional custom base URL for recipe files.
    /// When nil, uses `Bundle.module`.
    private let baseURL: URL?

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    enum LoaderError: Error, LocalizedError, Equatable, Sendable {
        case recipeNotFound(String)
        case invalidData
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case let .recipeNotFound(name):
                return "Recipe '\(name)' not found."
            case .invalidData:
                return "Recipe data could not be read."
            case let .validationFailed(error):
                return error
            }
        }
    }

    /// Load a recipe by its base name (without .json extension).
    /// - Parameter name: Recipe file name (e.g. "cloverpit")
    /// - Returns: A validated `GameRecipe`.
    func loadRecipe(named name: String) throws -> GameRecipe {
        let url: URL
        if let baseURL {
            url = baseURL.appendingPathComponent("\(name).json")
        } else {
            guard let bundleURL = Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Resources/Recipes"
            ) else {
                throw LoaderError.recipeNotFound(name)
            }
            url = bundleURL
        }

        return try loadRecipe(from: url)
    }

    /// Load raw data from a recipe URL (for testing with custom data).
    func loadRecipe(from url: URL) throws -> GameRecipe {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoaderError.recipeNotFound(url.lastPathComponent)
        }

        let decoder = JSONDecoder()
        let recipe: GameRecipe
        do {
            recipe = try decoder.decode(GameRecipe.self, from: data)
        } catch {
            throw LoaderError.invalidData
        }

        guard recipe.isValid else {
            throw LoaderError.validationFailed("Recipe failed schema validation")
        }

        return recipe
    }
}
