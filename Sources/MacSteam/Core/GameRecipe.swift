// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Describes a game that can be launched by MacSteam.
///
/// Recipes specify which store the game belongs to, which runtime
/// adapter is preferred, and how to launch the game.
///
/// Recipes do **not** contain absolute paths, credentials, or
/// personal information.
struct GameRecipe: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let store: StoreInfo
    let runtime: RuntimePreference
    let launch: LaunchConfig
    let detection: DetectionConfig
}

// MARK: - Nested types

extension GameRecipe {
    struct StoreInfo: Codable, Equatable, Sendable {
        let type: StoreType
        let appId: String
    }

    enum StoreType: String, Codable, Sendable {
        case steam
    }

    struct RuntimePreference: Codable, Equatable, Sendable {
        let preferredAdapter: String
    }

    struct LaunchConfig: Codable, Equatable, Sendable {
        let arguments: [String]
    }

    struct DetectionConfig: Codable, Equatable, Sendable {
        let manifestName: String
        /// Candidate game executable filenames (e.g. `["CloverPit.exe"]`).
        /// When non‑empty, at least one must be present in the install directory
        /// for `isReady` to be true.
        let executableCandidates: [String]?

        init(manifestName: String, executableCandidates: [String]? = nil) {
            self.manifestName = manifestName
            self.executableCandidates = executableCandidates
        }
    }
}

// MARK: - Validation

enum RecipeValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidJSON
    case unknownSchemaVersion(Int)
    case emptyAppID
    case absolutePathDetected(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Recipe file is not valid JSON."
        case let .unknownSchemaVersion(v):
            return "Unsupported recipe schema version: \(v)."
        case .emptyAppID:
            return "Recipe has an empty application identifier."
        case let .absolutePathDetected(field):
            return "Recipe contains an absolute path in field: \(field)."
        case let .missingRequiredField(field):
            return "Recipe is missing required field: \(field)."
        }
    }
}

extension GameRecipe {
    /// Validates the recipe against known rules.
    /// - Throws: `RecipeValidationError` if the recipe is not usable.
    func validate() throws {
        guard schemaVersion == 1 else {
            throw RecipeValidationError.unknownSchemaVersion(schemaVersion)
        }
        guard !store.appId.isEmpty else {
            throw RecipeValidationError.emptyAppID
        }
        guard !id.isEmpty else {
            throw RecipeValidationError.missingRequiredField("id")
        }
        guard !displayName.isEmpty else {
            throw RecipeValidationError.missingRequiredField("displayName")
        }
        // Reject any field containing an absolute path
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let value = child.value as? String, value.hasPrefix("/") {
                throw RecipeValidationError.absolutePathDetected(child.label ?? "unknown")
            }
        }
        // Also check nested fields
        if launch.arguments.contains(where: { $0.hasPrefix("/") }) {
            throw RecipeValidationError.absolutePathDetected("launch.arguments")
        }
    }
}
