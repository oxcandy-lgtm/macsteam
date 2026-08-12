// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A single canonical, machine-readable snapshot of the running MacsTeam
/// coordinator. Produced by the app's mirror loop; consumed verbatim by
/// `macsteamctl status --json`.
///
/// Security contract: this snapshot NEVER contains absolute paths, PIDs, or
/// Steam account/credential/session identity. Everything is a bounded flag or
/// enum raw value derived from production state.
public struct ControlPlaneSnapshot: Codable, Equatable, Sendable {
    public var schema_version: Int
    public var build_sha: String
    public var screen: String
    public var setup_state: String
    public var runtime: ControlPlaneRuntime
    public var prefix: ControlPlanePrefix
    public var steam: ControlPlaneSteam
    public var cloverpit: ControlPlaneCloverPit
    public var session: ControlPlaneSession
    public var actions: [String: ControlPlaneAction]
    public var installer: ControlPlaneInstaller
    public var last_transition: ControlPlaneTransition?
    public var last_error: ControlPlaneError?

    public init(
        schema_version: Int,
        build_sha: String,
        screen: String,
        setup_state: String,
        runtime: ControlPlaneRuntime,
        prefix: ControlPlanePrefix,
        steam: ControlPlaneSteam,
        cloverpit: ControlPlaneCloverPit,
        session: ControlPlaneSession,
        actions: [String: ControlPlaneAction],
        installer: ControlPlaneInstaller,
        last_transition: ControlPlaneTransition? = nil,
        last_error: ControlPlaneError? = nil
    ) {
        self.schema_version = schema_version
        self.build_sha = build_sha
        self.screen = screen
        self.setup_state = setup_state
        self.runtime = runtime
        self.prefix = prefix
        self.steam = steam
        self.cloverpit = cloverpit
        self.session = session
        self.actions = actions
        self.installer = installer
        self.last_transition = last_transition
        self.last_error = last_error
    }
}

/// Selected runtime projection.
public struct ControlPlaneRuntime: Codable, Equatable, Sendable {
    public var type: String
    public var selected: Bool
    public var real_load_healthy: Bool

    public init(type: String, selected: Bool, real_load_healthy: Bool) {
        self.type = type
        self.selected = selected
        self.real_load_healthy = real_load_healthy
    }
}

/// Canonical prefix projection.
public struct ControlPlanePrefix: Codable, Equatable, Sendable {
    public var bound: Bool
    public var valid: Bool

    public init(bound: Bool, valid: Bool) {
        self.bound = bound
        self.valid = valid
    }
}

/// Windows Steam projection (process + WindowServer visibility).
public struct ControlPlaneSteam: Codable, Equatable, Sendable {
    public var exe_present: Bool
    public var installed: Bool
    public var lifecycle: String
    public var running: Bool
    public var window_visible: Bool
    /// Bounded Steam client state label (stopped/launching/runningVisible/…).
    public var client_state: String

    public init(exe_present: Bool, installed: Bool, lifecycle: String, running: Bool, window_visible: Bool, client_state: String) {
        self.exe_present = exe_present
        self.installed = installed
        self.lifecycle = lifecycle
        self.running = running
        self.window_visible = window_visible
        self.client_state = client_state
    }
}

/// CloverPit projection (install + process + WindowServer visibility).
public struct ControlPlaneCloverPit: Codable, Equatable, Sendable {
    public var ready: Bool
    public var running: Bool
    public var window_visible: Bool
    public var install_state: String
    /// Bounded install facts from the production inspection — already-bounded
    /// booleans, never paths or identities (AI-CP-STEP3 doctor input).
    public var manifest_present: Bool
    public var install_directory_resolved: Bool
    public var executable_present: Bool
    public var canonical_install_present: Bool
    public var download_payload_present: Bool

    public init(
        ready: Bool,
        running: Bool,
        window_visible: Bool,
        install_state: String,
        manifest_present: Bool = false,
        install_directory_resolved: Bool = false,
        executable_present: Bool = false,
        canonical_install_present: Bool = false,
        download_payload_present: Bool = false
    ) {
        self.ready = ready
        self.running = running
        self.window_visible = window_visible
        self.install_state = install_state
        self.manifest_present = manifest_present
        self.install_directory_resolved = install_directory_resolved
        self.executable_present = executable_present
        self.canonical_install_present = canonical_install_present
        self.download_payload_present = download_payload_present
    }
}

/// Supervised session projection.
public struct ControlPlaneSession: Codable, Equatable, Sendable {
    public var purpose: String
    public var running: Bool
    public var window_visible: Bool

    public init(purpose: String, running: Bool, window_visible: Bool) {
        self.purpose = purpose
        self.running = running
        self.window_visible = window_visible
    }
}

/// Canonical action flag. GUI buttons and the terminal read the SAME model.
public struct ControlPlaneAction: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var source: String
    public var target: String
    public var disabled_reason: String?

    public init(id: String, enabled: Bool, source: String, target: String, disabled_reason: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.target = target
        self.disabled_reason = disabled_reason
    }
}

/// Installer projection (bounded: session ID, phase, latest message).
public struct ControlPlaneInstaller: Codable, Equatable, Sendable {
    public var session: String
    public var phase: String
    public var active: Bool
    public var message: String?
    public var last_error: String?

    public init(session: String, phase: String, active: Bool, message: String?, last_error: String? = nil) {
        self.session = session
        self.phase = phase
        self.active = active
        self.message = message
        self.last_error = last_error
    }
}

/// Last accepted/rejected navigation transition.
public struct ControlPlaneTransition: Codable, Equatable, Sendable {
    public var from: String?
    public var action: String
    public var to: String
    public var accepted: Bool

    public init(from: String?, action: String, to: String, accepted: Bool) {
        self.from = from
        self.action = action
        self.to = to
        self.accepted = accepted
    }
}

/// Structured, bounded error projection.
public struct ControlPlaneError: Codable, Equatable, Sendable {
    public var subsystem: String
    public var code: String
    public var message: String
    public var screen: String?
    public var last_action: String?

    public init(subsystem: String, code: String, message: String, screen: String? = nil, last_action: String? = nil) {
        self.subsystem = subsystem
        self.code = code
        self.message = message
        self.screen = screen
        self.last_action = last_action
    }
}

/// One structured event line in `events.ndjson`.
public struct ControlPlaneEvent: Codable, Equatable, Sendable {
    public var event: String
    public var ts: Double
    public var screen: String?
    public var setup_state: String?
    public var from: String?
    public var to: String?
    public var action: String?
    public var accepted: Bool?
    public var message: String?
    public var error: ControlPlaneError?

    public init(
        event: String,
        ts: Double,
        screen: String? = nil,
        setup_state: String? = nil,
        from: String? = nil,
        to: String? = nil,
        action: String? = nil,
        accepted: Bool? = nil,
        message: String? = nil,
        error: ControlPlaneError? = nil
    ) {
        self.event = event
        self.ts = ts
        self.screen = screen
        self.setup_state = setup_state
        self.from = from
        self.to = to
        self.action = action
        self.accepted = accepted
        self.message = message
        self.error = error
    }
}
