// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

import Foundation

/// Represents the current phase of the Steam installation lifecycle.
///
/// Phases are divided into three categories:
/// - **Inactive idle**: the initial state before any work begins.
/// - **Active phases** (``isActive``): the installer is doing work.
/// - **Terminal phases** (``isTerminal``): the installation has reached a final
///   state (success, interruption, failure, or awaiting cleanup).
enum InstallerPhase: String, Codable, Sendable, Equatable {
    case idle
    case preflightCleaning
    case prefixPreparing
    case installerLaunching
    case installerRunning
    case installerExited
    case steamBootstrapDetected
    case bootstrapStopping
    case verifyingInstallation
    case steamReady
    case steamLaunching
    case steamVisible
    case steamHidden
    case stopping
    case interrupted
    case cleanupRequired
    case failed

    /// Whether the phase represents active installation work.
    ///
    /// Returns `true` for every phase that is neither terminal nor the idle
    /// starting state.
    var isActive: Bool { !isTerminal && self != .idle }

    /// Whether the phase is a terminal state.
    ///
    /// Terminal states are: ``steamReady``, ``interrupted``, ``cleanupRequired``,
    /// and ``failed``. Once reached, the only valid transition is back to
    /// ``idle`` (for retry/cleanup) or onward to a cleanup flow.
    var isTerminal: Bool {
        self == .steamReady
            || self == .interrupted
            || self == .cleanupRequired
            || self == .failed
    }
}
