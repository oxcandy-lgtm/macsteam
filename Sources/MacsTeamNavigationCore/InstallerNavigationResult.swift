// SPDX-License-Identifier: GPL-3.0-or-later

// MARK: - Supporting types

/// A navigation blocker that prevents a transition and provides a reason.
public struct InstallerNavigationBlocker: Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

extension InstallerNavigationBlocker {
    /// The current page is not yet marked complete.
    static let pageIncomplete = InstallerNavigationBlocker(
        code: "page_incomplete",
        message: "Current page has not been completed."
    )

    /// An active operation is in progress and must be stopped first.
    static let activeOperationInProgress = InstallerNavigationBlocker(
        code: "active_operation",
        message: "An operation is currently active. Stop it before navigating."
    )

    /// Cleanup is required before transitions are allowed.
    static let cleanupRequired = InstallerNavigationBlocker(
        code: "cleanup_required",
        message: "Cleanup is required before navigation."
    )

    /// The current page could not be found in the canonical page list.
    static let internalError = InstallerNavigationBlocker(
        code: "internal_error",
        message: "Current page is not in the page sequence."
    )
}

/// The outcome of processing a navigation intent.
public struct InstallerNavigationResult: Sendable {
    /// Whether the intent was accepted (transition occurred).
    public let accepted: Bool
    /// The page navigated to, if the transition succeeded and moved.
    /// `nil` when staying on the current page (e.g. already at boundary).
    public let newPage: InstallerPage?
    /// A blocker that prevented the transition, if any.
    public let blocker: InstallerNavigationBlocker?

    public init(
        accepted: Bool,
        newPage: InstallerPage? = nil,
        blocker: InstallerNavigationBlocker? = nil
    ) {
        self.accepted = accepted
        self.newPage = newPage
        self.blocker = blocker
    }
}

/// An immutable point-in-time snapshot of the reducer's state.
public struct InstallerNavigationSnapshot: Sendable {
    public let currentPage: InstallerPage
    public let result: InstallerNavigationResult?
}
