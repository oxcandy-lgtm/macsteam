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

extension SteamClientState {
    /// U1R18 R1: map the WindowServer-observed `GameSessionState` onto the
    /// Steam client state. Visibility is measured by the supervisor's
    /// `SessionWindowObserver`, never guessed here.
    ///
    /// `.runningUnknown` maps to `.launching` — the process is alive but the
    /// observer has not yet confirmed a window on the WindowServer.
    init(sessionState: GameSessionState) {
        switch sessionState {
        case .runningVisible:
            self = .runningVisible
        case .runningHidden:
            self = .runningHidden
        case .runningUnknown, .launching:
            self = .launching
        case .stopping:
            self = .stopping
        case .stopped, .idle:
            self = .stopped
        case .recoveryRequired(let message):
            self = .recoveryRequired(message)
        case .failed(let message):
            self = .recoveryRequired(message)
        }
    }
}
