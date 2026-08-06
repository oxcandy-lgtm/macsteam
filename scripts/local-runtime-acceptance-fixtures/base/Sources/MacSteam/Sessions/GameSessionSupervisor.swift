// SPDX-License-Identifier: GPL-3.0-or-later

enum GameSessionState: Sendable, Equatable {
    case idle
    case launching
    case unknown
    case runningVisible
    case runningHidden
    case stopping
    case stopped
    case failed(String)
}

struct GameSessionSubject {
    var sessionID: UUID
    var recipeID: String
}

protocol SessionObserver {}