// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// States for the MacSteam Ultimate setup flow.
///
/// Each case represents a step along the path from initial system
/// inspection through to launching CloverPit.  Error information is
/// stored separately in the view model rather than as an associated
/// value so the enum stays simple and UI-friendly.
enum UltimateSetupState: String, Sendable, Equatable, CaseIterable {
    /// Initial state — performing system checks.
    case inspecting
    /// No compatible Wine runtime was found.
    case runtimeRequired
    /// A runtime was found but failed validation.
    case runtimeInvalid
    /// A valid runtime is available.
    case runtimeReady
    /// No CloverPit environment (Wine prefix) exists yet.
    case prefixRequired
    /// The prefix has been created.
    case prefixReady
    /// The user needs to download the Steam installer manually.
    case steamInstallerRequired
    /// The downloaded installer has been verified.
    case steamInstallerVerified
    /// The installer is being run inside the prefix.
    case steamInstallationPending
    /// Windows Steam is detected inside the prefix.
    case steamReady
    /// Steam is present but CloverPit is not installed.
    case cloverPitNotInstalled
    /// CloverPit is ready to launch.
    case cloverPitReady
    /// A launch is in progress.
    case launching
    /// The launch command has been submitted.
    case launchSubmitted

    // MARK: - Display helpers

    /// A user-facing label for the current state.
    var displayName: String {
        switch self {
        case .inspecting:              return "Inspecting system…"
        case .runtimeRequired:         return "Runtime required"
        case .runtimeInvalid:          return "Runtime invalid"
        case .runtimeReady:            return "Runtime ready"
        case .prefixRequired:          return "Prefix required"
        case .prefixReady:             return "Prefix ready"
        case .steamInstallerRequired:  return "Steam installer required"
        case .steamInstallerVerified:  return "Installer verified"
        case .steamInstallationPending:return "Installing Steam…"
        case .steamReady:              return "Steam ready"
        case .cloverPitNotInstalled:   return "CloverPit not installed"
        case .cloverPitReady:          return "Ready to launch"
        case .launching:               return "Launching…"
        case .launchSubmitted:         return "Launch submitted"
        }
    }

    /// Whether this state represents a completed step.
    var isComplete: Bool {
        switch self {
        case .runtimeReady, .prefixReady, .steamInstallerVerified,
             .steamReady, .cloverPitReady:
            return true
        default:
            return false
        }
    }

    /// Whether this state represents an error or blocking condition.
    var isBlocking: Bool {
        switch self {
        case .runtimeInvalid, .runtimeRequired, .prefixRequired,
                .steamInstallerRequired, .cloverPitNotInstalled:
            return true
        default:
            return false
        }
    }

}
