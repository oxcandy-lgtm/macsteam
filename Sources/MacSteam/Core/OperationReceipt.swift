// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A persistent receipt recording a MacSteam operation.
///
/// Receipts are stored under `~/Library/Application Support/MacSteam/Receipts/`.
/// They provide an audit trail for prefix creation, runtime installation,
/// Steam setup, and other non-trivial operations.
public struct OperationReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let operation: OperationKind
    public let recipeId: String?
    public let runtimeId: String?
    public let runtimeManifestHash: String?
    public let recipeHash: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let result: OperationResult
    /// Whether personal paths (e.g. $HOME) appear in the receipt output.
    public let personalPathOutput: Bool
    /// Whether credentials or secrets appear in the receipt output.
    public let credentialOutput: Bool

    public init(
        schemaVersion: Int = 1,
        operation: OperationKind,
        recipeId: String? = nil,
        runtimeId: String? = nil,
        runtimeManifestHash: String? = nil,
        recipeHash: String? = nil,
        startedAt: Date,
        finishedAt: Date,
        result: OperationResult,
        personalPathOutput: Bool = false,
        credentialOutput: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.recipeId = recipeId
        self.runtimeId = runtimeId
        self.runtimeManifestHash = runtimeManifestHash
        self.recipeHash = recipeHash
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.personalPathOutput = personalPathOutput
        self.credentialOutput = credentialOutput
    }
}

/// The kind of operation recorded.
public enum OperationKind: String, Codable, Sendable, Equatable {
    case createPrefix = "create-prefix"
    case destroyPrefix = "destroy-prefix"
    case installRuntime = "install-runtime"
    case removeRuntime = "remove-runtime"
    case installSteam = "install-steam"
    case launchGame = "launch-game"
    case repairPrefix = "repair-prefix"
    case snapshotPrefix = "snapshot-prefix"
}

/// The outcome of an operation.
public enum OperationResult: String, Codable, Sendable, Equatable {
    case success
    case failure
    case cancelled
    case dryRun = "dry-run"
}
