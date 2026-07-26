// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of inspecting a compatibility runtime.
public struct RuntimeInspection: Sendable, Equatable {
    public let runtimeID: String
    public let displayName: String
    public let version: String?
    public let architecture: String?
    public let isUsable: Bool
    public let capabilities: RuntimeCapabilities
    public let failures: [RuntimeFailure]

    public init(
        runtimeID: String,
        displayName: String = "",
        version: String? = nil,
        architecture: String? = nil,
        isUsable: Bool,
        capabilities: RuntimeCapabilities = [],
        failures: [RuntimeFailure] = []
    ) {
        self.runtimeID = runtimeID
        self.displayName = displayName.isEmpty ? runtimeID : displayName
        self.version = version
        self.architecture = architecture
        self.isUsable = isUsable
        self.capabilities = capabilities
        self.failures = failures
    }
}

/// A failure found during runtime inspection.
public struct RuntimeFailure: Error, Sendable, Equatable {
    public let code: RuntimeFailureCode
    public let message: String

    public init(code: RuntimeFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RuntimeFailureCode: String, Sendable, Equatable {
    case bundleNotValid
    case executableMissing
    case wineserverMissing
    case winebootMissing
    case symlinkEscape
    case worldWritable
    case architectureProbeFailed
    case versionProbeFailed
    case dynamicLibraryMissing
    case runtimeRootNotFound
    case invalidManifest
    case missingLicense
    case unknownSPDX
    case forbiddenRedistribution

    /// Backward compatibility with old enum values.
    var oldFailure: Self {
        switch self {
        case .executableMissing, .bundleNotValid: return self
        default: return .bundleNotValid
        }
    }
}

/// Protocol for all compatibility runtime implementations.
///
/// Adapters are registered in priority order:
///   1. ManagedWineRuntime
///   2. ImportedWineRuntime
///   3. SystemWineRuntime
///   4. CrossOverRuntime (optional fallback)
protocol CompatibilityRuntime: Sendable {
    /// Unique identifier for this runtime class (e.g. "imported-wine").
    static var runtimeID: String { get }

    /// Initialize with a specific root URL (e.g. user-selected directory).
    init?(url: URL)

    /// Inspect the runtime and return its capabilities.
    func inspect() -> RuntimeInspection

    /// Whether this runtime executable can be found at the expected system location.
    static func detectSystem() -> Bool

    /// The preferred launch plan for this runtime given a game recipe.
    func launchPlan(for recipe: GameRecipe) -> LaunchPlan?

    /// Validate that the runtime is in a safe state to use.
    func validate() throws
}
