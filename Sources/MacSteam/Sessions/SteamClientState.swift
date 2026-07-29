// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Independent state of the Steam Client process, separate from GameSession.
///
/// This tracks Steam.exe itself, not a game session. Use this to determine
/// whether to launch, show, or stop the Steam UI.
enum SteamClientState: Codable, Sendable, Equatable {
    /// No Steam process, no wineserver, no receipt.
    case stopped
    /// Steam process is starting up.
    case launching
    /// Steam has a visible window.
    case runningVisible
    /// Steam window was closed (red X) but process remains.
    case runningHidden
    /// steam.exe is gone but wineserver/helper processes remain.
    case stale
    /// Steam is being shut down.
    case stopping
    /// Steam cannot start due to a deterministic error.
    case recoveryRequired(String)
}
