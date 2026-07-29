// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The outcome of a Wine prefix cleanup attempt.
enum PrefixCleanupResult: Sendable, Equatable {
    /// All known processes terminated and wineserver shut down cleanly.
    case clean
    /// One or more processes or the wineserver could not be stopped,
    /// or non-fatal errors were encountered during cleanup.
    case incomplete(reason: String)
}
