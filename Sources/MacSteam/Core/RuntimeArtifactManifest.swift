// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Describes the runtime architecture of a Wine/Windows compatibility runtime.
public struct RuntimeArchitecture: Codable, Sendable, Equatable {
    public let arch: String
    public let name: String
    public let wow64: Bool?

    public init(arch: String, name: String, wow64: Bool? = nil) {
        self.arch = arch
        self.name = name
        self.wow64 = wow64
    }
}

/// Identifies the source of a runtime artifact.
public struct SourceIdentity: Codable, Sendable, Equatable {
    public let upstreamRepository: String
    public let upstreamCommit: String
    public let sourceArchiveSHA256: String
    public let patchsetSHA256: String?
    public let buildRecipeSHA256: String

    public init(
        upstreamRepository: String,
        upstreamCommit: String,
        sourceArchiveSHA256: String,
        patchsetSHA256: String? = nil,
        buildRecipeSHA256: String
    ) {
        self.upstreamRepository = upstreamRepository
        self.upstreamCommit = upstreamCommit
        self.sourceArchiveSHA256 = sourceArchiveSHA256
        self.patchsetSHA256 = patchsetSHA256
        self.buildRecipeSHA256 = buildRecipeSHA256
    }
}

/// Describes the license terms for a runtime component.
public struct LicenseIdentity: Codable, Sendable, Equatable {
    public let spdx: String
    public let licenseFiles: [String]
    public let noticeFiles: [String]
    public let redistribution: RedistributionClass

    public init(spdx: String, licenseFiles: [String], noticeFiles: [String], redistribution: RedistributionClass) {
        self.spdx = spdx
        self.licenseFiles = licenseFiles
        self.noticeFiles = noticeFiles
        self.redistribution = redistribution
    }
}

/// How a component may be redistributed.
public enum RedistributionClass: String, Codable, Sendable, Equatable {
    case allowed
    case allowedWithConditions
    case reviewRequired
    case forbidden
}

/// Identifies a binary archive.
public struct ArchiveIdentity: Codable, Sendable, Equatable {
    public let filename: String
    public let sha256: String
    public let size: UInt64

    public init(filename: String, sha256: String, size: UInt64) {
        self.filename = filename
        self.sha256 = sha256
        self.size = size
    }
}

/// Capabilities that a compatibility runtime may declare.
public struct RuntimeCapabilities: Codable, Sendable, Equatable, OptionSet {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let windowsProcess  = RuntimeCapabilities(rawValue: 1 << 0)
    public static let steamClient     = RuntimeCapabilities(rawValue: 1 << 1)
    public static let isolatedPrefix  = RuntimeCapabilities(rawValue: 1 << 2)
    public static let d3d             = RuntimeCapabilities(rawValue: 1 << 3)
    public static let vulkan          = RuntimeCapabilities(rawValue: 1 << 4)
    public static let metal           = RuntimeCapabilities(rawValue: 1 << 5)
    public static let wined3d         = RuntimeCapabilities(rawValue: 1 << 6)
    public static let wow64           = RuntimeCapabilities(rawValue: 1 << 7)
}

/// Full manifest describing a runtime artifact.
public struct RuntimeArtifactManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let hostArchitectures: [HostArchitecture]
    public let runtimeArchitectures: [RuntimeArchitecture]
    public let minimumMacOS: String
    public let source: SourceIdentity
    public let license: LicenseIdentity
    public let archive: ArchiveIdentity
    public let capabilities: RuntimeCapabilities

    /// Whether the manifest is semantically valid (all required fields populated).
    public var isValid: Bool {
        guard schemaVersion == 1 else { return false }
        guard !id.isEmpty, !version.isEmpty else { return false }
        guard !source.upstreamRepository.isEmpty else { return false }
        guard !source.upstreamCommit.isEmpty else { return false }
        guard source.sourceArchiveSHA256.count == 64 else { return false }
        guard source.buildRecipeSHA256.count == 64 else { return false }
        guard !license.spdx.isEmpty else { return false }
        guard !archive.filename.isEmpty else { return false }
        guard archive.sha256.count == 64 else { return false }
        guard !minimumMacOS.isEmpty else { return false }
        return true
    }
}

/// Host CPU architecture.
public struct HostArchitecture: Codable, Sendable, Equatable {
    public let arch: String
    public let name: String

    public init(arch: String, name: String) {
        self.arch = arch
        self.name = name
    }
}
