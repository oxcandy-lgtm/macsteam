// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One command the terminal submits to the running MacsTeam app through the
/// file mailbox. Written by `macsteamctl` into `commands/inbox/`.
///
/// Security contract: the request carries ONLY a canonical action id and an
/// optional bounded argument. It NEVER carries Steam account, credential, or
/// session identity. The only allowed argument is a user-supplied local path
/// for `steam.select_installer`; that path is never copied into snapshots,
/// events, or responses.
public struct ControlPlaneCommandRequest: Codable, Equatable, Sendable {
    public var schema_version: Int
    public var id: String
    public var action: String
    public var argument: String?
    public var created_at: Double

    public init(
        schema_version: Int = 1,
        id: String,
        action: String,
        argument: String? = nil,
        created_at: Double = Date().timeIntervalSince1970
    ) {
        self.schema_version = schema_version
        self.id = id
        self.action = action
        self.argument = argument
        self.created_at = created_at
    }
}

/// Terminal outcome of a control-plane action.
public enum ControlPlaneCommandStatus: String, Codable, Sendable {
    case accepted
    case rejected
    case failed
}

/// The production response the app writes into `commands/outbox/` after
/// executing (or refusing) a request.
public struct ControlPlaneCommandResponse: Codable, Equatable, Sendable {
    public var schema_version: Int
    public var id: String
    public var action: String
    public var status: ControlPlaneCommandStatus
    public var error_code: String?
    public var message: String?

    public init(
        schema_version: Int = 1,
        id: String,
        action: String,
        status: ControlPlaneCommandStatus,
        error_code: String? = nil,
        message: String? = nil
    ) {
        self.schema_version = schema_version
        self.id = id
        self.action = action
        self.status = status
        self.error_code = error_code
        self.message = message
    }
}

/// Result of a production intent invocation, produced by the app router.
public struct ControlPlaneCommandResult: Codable, Equatable, Sendable {
    public var status: ControlPlaneCommandStatus
    public var error_code: String?
    public var message: String?

    public init(status: ControlPlaneCommandStatus, error_code: String? = nil, message: String? = nil) {
        self.status = status
        self.error_code = error_code
        self.message = message
    }

    public static let accepted = ControlPlaneCommandResult(status: .accepted)
}

/// App aliveness inferred from the heartbeat file.
public enum ControlPlaneAppAliveness: Equatable, Sendable {
    /// Heartbeat is fresh — the app is running and responding.
    case running
    /// No heartbeat file — the app is not running.
    case notRunning
    /// Heartbeat exists but is stale — the app is unresponsive or crashed.
    case unresponsive(staleSeconds: Double)
}