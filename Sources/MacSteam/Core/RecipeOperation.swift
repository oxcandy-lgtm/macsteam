// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A restricted set of typed operations that a game recipe may perform.
///
/// Arbitrary shell execution, sudo, and uncontrolled downloads are forbidden.
/// Only these operations appear in a validated recipe.
public enum RecipeOperation: Codable, Sendable, Equatable {
    case setWindowsVersion(String)
    case setRegistryValue(RegistryMutation)
    case setDLLOverride(DLLOverride)
    case setEnvironment(AllowedEnvironmentMutation)
    case copyBundledOpenSourceComponent(ComponentCopy)
    case verifyFile(FileVerification)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case setWindowsVersion
        case setRegistryValue
        case setDLLOverride
        case setEnvironment
        case copyBundledOpenSourceComponent
        case verifyFile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .setWindowsVersion:
            let value = try container.decode(String.self, forKey: .value)
            self = .setWindowsVersion(value)
        case .setRegistryValue:
            let value = try container.decode(RegistryMutation.self, forKey: .value)
            self = .setRegistryValue(value)
        case .setDLLOverride:
            let value = try container.decode(DLLOverride.self, forKey: .value)
            self = .setDLLOverride(value)
        case .setEnvironment:
            let value = try container.decode(AllowedEnvironmentMutation.self, forKey: .value)
            self = .setEnvironment(value)
        case .copyBundledOpenSourceComponent:
            let value = try container.decode(ComponentCopy.self, forKey: .value)
            self = .copyBundledOpenSourceComponent(value)
        case .verifyFile:
            let value = try container.decode(FileVerification.self, forKey: .value)
            self = .verifyFile(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setWindowsVersion(let v):
            try container.encode(Kind.setWindowsVersion, forKey: .kind)
            try container.encode(v, forKey: .value)
        case .setRegistryValue(let v):
            try container.encode(Kind.setRegistryValue, forKey: .kind)
            try container.encode(v, forKey: .value)
        case .setDLLOverride(let v):
            try container.encode(Kind.setDLLOverride, forKey: .kind)
            try container.encode(v, forKey: .value)
        case .setEnvironment(let v):
            try container.encode(Kind.setEnvironment, forKey: .kind)
            try container.encode(v, forKey: .value)
        case .copyBundledOpenSourceComponent(let v):
            try container.encode(Kind.copyBundledOpenSourceComponent, forKey: .kind)
            try container.encode(v, forKey: .value)
        case .verifyFile(let v):
            try container.encode(Kind.verifyFile, forKey: .kind)
            try container.encode(v, forKey: .value)
        }
    }
}

/// A registry key/value pair to set in the Wine prefix.
public struct RegistryMutation: Codable, Sendable, Equatable {
    public let key: String
    public let value: String
    public let data: String

    public init(key: String, value: String, data: String) {
        self.key = key
        self.value = value
        self.data = data
    }
}

/// A DLL override directive for Wine.
public struct DLLOverride: Codable, Sendable, Equatable {
    public let library: String
    public let mode: DLLOverrideMode

    public init(library: String, mode: DLLOverrideMode) {
        self.library = library
        self.mode = mode
    }
}

public enum DLLOverrideMode: String, Codable, Sendable, Equatable {
    case `native`
    case builtin
    case nativeThenBuiltin
    case builtinThenNative
    case disabled
}

/// An environment variable that may be set from an allow-list.
public struct AllowedEnvironmentMutation: Codable, Sendable, Equatable {
    /// The allow-listed key.
    public let key: AllowedEnvKey
    public let value: String

    public init(key: AllowedEnvKey, value: String) {
        self.key = key
        self.value = value
    }
}

/// The set of environment variables that a recipe is allowed to set.
public enum AllowedEnvKey: String, Codable, Sendable, Equatable, CaseIterable {
    case winprefix = "WINEPREFIX"
    case winedebug = "WINEDEBUG"
    case dxvkLogLevel = "DXVK_LOG_LEVEL"
    case dxvkStateCachePath = "DXVK_STATE_CACHE_PATH"
    case moltenvkConfigFile = "MOLTENVK_CONFIG_FILE"
}

/// Copy an open-source component bundled with MacSteam into the prefix.
public struct ComponentCopy: Codable, Sendable, Equatable {
    /// Relative path within the MacSteam app bundle.
    public let sourceRelativePath: String
    /// Relative path within the prefix.
    public let destinationRelativePath: String

    public init(sourceRelativePath: String, destinationRelativePath: String) {
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
    }
}

/// Verify a file exists at a relative path within the prefix.
public struct FileVerification: Codable, Sendable, Equatable {
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }
}
