// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A validated game recipe that describes how to detect, install, and launch
/// a specific Windows game using MacSteam's runtime adapters.
///
/// Schema version 2 — all recipe files must carry `schemaVersion: 2`.
public struct GameRecipe: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let store: StoreInfo
    public let runtime: RuntimeRequirements
    public let graphics: GraphicsConfig
    public let prefix: PrefixConfig
    public let storeInstallation: StoreInstallationConfig
    public let launch: LaunchConfig
    public let detection: DetectionConfig
    public let savePolicy: SavePolicyConfig

    // MARK: - Nested types

    public struct StoreInfo: Codable, Sendable, Equatable {
        public let type: StoreType
        public let appId: String

        public init(type: StoreType, appId: String) {
            self.type = type
            self.appId = appId
        }
    }

    public enum StoreType: String, Codable, Sendable, Equatable {
        case steam
    }

    public struct RuntimeRequirements: Codable, Sendable, Equatable {
        public let requiredCapabilities: [String]
        public let preferredRuntime: RuntimeKind
        public let fallbackRuntimes: [RuntimeKind]

        public init(requiredCapabilities: [String], preferredRuntime: RuntimeKind, fallbackRuntimes: [RuntimeKind]) {
            self.requiredCapabilities = requiredCapabilities
            self.preferredRuntime = preferredRuntime
            self.fallbackRuntimes = fallbackRuntimes
        }
    }

    public enum RuntimeKind: String, Codable, Sendable, Equatable {
        case managedWine = "managed-wine"
        case importedWine = "imported-wine"
        case systemWine = "system-wine"
        case crossover = "crossover"
    }

    public struct GraphicsConfig: Codable, Sendable, Equatable {
        public let preferred: GraphicsBackend
        public let fallback: [GraphicsBackend]

        public init(preferred: GraphicsBackend, fallback: [GraphicsBackend]) {
            self.preferred = preferred
            self.fallback = fallback
        }
    }

    public enum GraphicsBackend: String, Codable, Sendable, Equatable {
        case wined3d
        case dxvk
        case moltenvk
        case d3dmetal
    }

    public struct PrefixConfig: Codable, Sendable, Equatable {
        public let id: String
        public let windowsVersion: WindowsVersion
        public let isolation: PrefixIsolation

        public init(id: String, windowsVersion: WindowsVersion, isolation: PrefixIsolation) {
            self.id = id
            self.windowsVersion = windowsVersion
            self.isolation = isolation
        }
    }

    public enum WindowsVersion: String, Codable, Sendable, Equatable {
        case win10
        case win81
        case win7
    }

    public enum PrefixIsolation: String, Codable, Sendable, Equatable {
        case perGame = "per-game"
        case shared
    }

    public struct StoreInstallationConfig: Codable, Sendable, Equatable {
        public let installerMode: InstallerMode
        public let installerProduct: String
        public let redistribution: RedistributionMode

        public init(installerMode: InstallerMode, installerProduct: String, redistribution: RedistributionMode) {
            self.installerMode = installerMode
            self.installerProduct = installerProduct
            self.redistribution = redistribution
        }
    }

    public enum InstallerMode: String, Codable, Sendable, Equatable {
        case userSelectedFile = "user-selected-file"
        case automatic
    }

    public enum RedistributionMode: String, Codable, Sendable, Equatable {
        case forbidden
        case allowed
        case reviewRequired = "review-required"
    }

    public struct LaunchConfig: Codable, Sendable, Equatable {
        public let storeArguments: [String]

        public init(storeArguments: [String]) {
            self.storeArguments = storeArguments
        }
    }

    public struct DetectionConfig: Codable, Sendable, Equatable {
        public let manifestName: String
        public let executableCandidates: [String]

        public init(manifestName: String, executableCandidates: [String]) {
            self.manifestName = manifestName
            self.executableCandidates = executableCandidates
        }
    }

    public struct SavePolicyConfig: Codable, Sendable, Equatable {
        public let mode: SaveMode
        public let backupBeforeDestructiveRepair: Bool

        public init(mode: SaveMode, backupBeforeDestructiveRepair: Bool) {
            self.mode = mode
            self.backupBeforeDestructiveRepair = backupBeforeDestructiveRepair
        }
    }

    public enum SaveMode: String, Codable, Sendable, Equatable {
        case discoverOnly = "discover-only"
        case backupEnabled = "backup-enabled"
        case fullManaged = "full-managed"
    }

    // MARK: - Validation

    /// Validate the recipe against known schema constraints.
    public var isValid: Bool {
        guard schemaVersion == 2 else { return false }
        guard !id.isEmpty, !displayName.isEmpty else { return false }
        guard !store.appId.isEmpty else { return false }
        guard !launch.storeArguments.isEmpty else { return false }
        guard !detection.executableCandidates.isEmpty else { return false }
        return true
    }
}
