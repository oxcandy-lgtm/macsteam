// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Tracks the lifecycle of a Steam installation in a Wine prefix.
///
/// This is the single source of truth for whether Steam is available to launch.
/// The mere presence of `steam.exe` on disk is NOT sufficient — the installation
/// must have reached ``verifiedComplete`` through a controlled lifecycle.
enum SteamInstallLifecycle: String, Codable, Sendable, Equatable {
    /// No Steam installation has been started in this prefix.
    case absent
    /// SteamSetup.exe is currently running or has been launched.
    case installing
    /// A previous installation was interrupted (MacsTeam restart, crash, etc.).
    case interrupted
    /// Installation has completed and been verified through the full lifecycle.
    case verifiedComplete
}

/// Evidence about the current Steam installation state on disk.
///
/// Separates file-system detection from lifecycle state. Even if
/// `steamExePresent` is true, ``canLaunchSteam`` returns `false` unless
/// the lifecycle has reached ``verifiedComplete``.
struct SteamInstallEvidence: Sendable, Equatable {
    /// Whether `steam.exe` exists on disk (non-empty).
    let steamExePresent: Bool
    /// Whether `steam.exe` has a non-zero file size.
    let steamExeNonEmpty: Bool
    /// Whether SteamSetup.exe is currently running (supervisor-owned).
    let installerRunning: Bool
    /// The current lifecycle state from persistent receipt.
    let lifecycle: SteamInstallLifecycle

    /// Whether Steam can be launched.
    ///
    /// Requires all of:
    /// - Lifecycle is ``verifiedComplete``
    /// - `steam.exe` exists on disk
    /// - `steam.exe` is non-empty
    var canLaunchSteam: Bool {
        lifecycle == .verifiedComplete
        && steamExePresent
        && steamExeNonEmpty
        && !installerRunning
    }

    /// Whether the installation is blocked and needs user action.
    var isIncomplete: Bool {
        lifecycle == .installing || lifecycle == .interrupted
    }
}
