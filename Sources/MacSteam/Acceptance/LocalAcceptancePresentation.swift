// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// U1R18-R11-FIX1: presentation model for the CloverPit acceptance UI.
///
/// The coordinator derives this from the acceptance authority's read-only
/// surface; the view renders only from this model and never decides policy.
/// Keeping it free of raw PIDs, paths, window identity and session internals
/// ensures the sensitive identity is bound at the cluster screen rather than
/// the view.
public struct LocalAcceptancePresentation {
    /// Whether the acceptance panel is visible at all. Independent of any
    /// launch result: a blocked or invalidated acceptance still surfaces so the
    /// operator can act or retry.
    public let isVisible: Bool

    /// Whether the "confirm main menu" step is enabled.
    public let canConfirmMainMenu: Bool

    /// Whether the "confirm input response" step is enabled.
    public let canConfirmInputResponse: Bool

    /// Whether the "complete acceptance" step is enabled.
    public let canComplete: Bool

    /// Stable display copy (no raw identifiers).
    public let title: String

    /// Stable display copy.
    public let body: String

    public init(
        isVisible: Bool,
        canConfirmMainMenu: Bool,
        canConfirmInputResponse: Bool,
        canComplete: Bool,
        title: String,
        body: String
    ) {
        self.isVisible = isVisible
        self.canConfirmMainMenu = canConfirmMainMenu
        self.canConfirmInputResponse = canConfirmInputResponse
        self.canComplete = canComplete
        self.title = title
        self.body = body
    }
}