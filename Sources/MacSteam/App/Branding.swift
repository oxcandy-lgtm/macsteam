// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Centralised branding constants.
///
/// All user-facing product names are defined here so that renaming
/// the project does not require touching the core logic.
enum AppBrand {
    /// The public display name shown in the UI.
    static let displayName = "MacSteam"

    /// The GitHub repository name (owner/name or just name).
    static let repositoryName = "macsteam"

    /// Support / project name used in menus and about panels.
    static let supportName = "MacSteam Project"

    /// Reverse‑DNS bundle identifier.
    static let bundleIdentifier = "app.macsteam.launcher"
}
