// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Snapshot of a runtime’s properties after inspection.
struct RuntimeInspection: Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String?
    let bundleURL: URL
    let isValid: Bool
    let failure: RuntimeFailure?
}

/// Snapshot of a game’s installation state within a runtime.
struct GameInspection: Equatable, Sendable {
    let recipeID: String
    let steamPresent: Bool
    let isWindowsSteam: Bool
    let manifestPresent: Bool
    let installDirectoryResolved: Bool
    let executablePresent: Bool
    let isReady: Bool
}
