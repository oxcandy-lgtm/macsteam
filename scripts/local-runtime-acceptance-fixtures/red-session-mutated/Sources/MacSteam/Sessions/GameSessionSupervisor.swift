// SPDX-License-Identifier: GPL-3.0-or-later

enum GameSessionState: Sendable, Equatable {
    case idle
    case launching
    case runningVisible
    case runningHidden
    case runningUnknown
    case stopping
    case stopped
    case failed(String)
    // mutation: added recoveryRequired
    case recoveryRequired(String)
}