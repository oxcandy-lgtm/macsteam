// SPDX-License-Identifier: GPL-3.0-or-later

/// Represents navigation actions available in the Steam installer flow.
public enum InstallerNavigationIntent: String, Codable, Sendable {
    case back
    case next
    case stopAndClean
}
