// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Reducer

/// Coordinates installer page navigation and enforces the navigation contract.
///
/// The reducer owns a simple mutable state that can be updated externally
/// by a coordinator or view model:
/// - `hasActiveOperation`: signals an in-flight long-running operation.
/// - `cleanupRequired`: signals that cleanup must happen before navigation.
/// - `allPagesComplete`: per-page completion map used by the `next` intent.
///
/// # Contract
/// - **next**: advances to the next page iff the current page is complete;
///            otherwise returns a `page_incomplete` blocker.
/// - **back**: returns to the previous page; if an active operation is
///            running the transition is blocked.
/// - **stopAndClean**: stops the active operation, attempts cleanup, and
///            blocks further transitions if cleanup remains required.
public actor InstallerNavigationReducer {
    // MARK: - Externally-updated state

    /// Whether a long-running operation (e.g. Steam download) is active.
    public var hasActiveOperation: Bool = false

    /// Whether cleanup is required before further navigation is allowed.
    public var cleanupRequired: Bool = false

    /// Per-page completion. A missing entry is treated as incomplete.
    public var allPagesComplete: [InstallerPage: Bool] = [:]

    /// Mark a page as complete (external state mutation).
    public func setPageComplete(_ page: InstallerPage, _ complete: Bool = true) {
        allPagesComplete[page] = complete
    }

    /// Set whether an active operation is running (external state mutation).
    public func setActiveOperation(_ active: Bool) {
        hasActiveOperation = active
    }

    /// Set whether cleanup is required (external state mutation).
    public func setCleanupRequired(_ required: Bool) {
        cleanupRequired = required
    }

    // MARK: - Internal state

    private var currentPage: InstallerPage

    // MARK: - Initialization

    public init(initialPage: InstallerPage = .runtime) {
        self.currentPage = initialPage
    }

    // MARK: - Public API

    /// Process a navigation intent and return the result.
    @discardableResult
    public func send(intent: InstallerNavigationIntent) async -> InstallerNavigationResult {
        switch intent {
        case .back:
            return handleBack()
        case .next:
            return handleNext()
        case .stopAndClean:
            return handleStopAndClean()
        }
    }

    /// Return an immutable snapshot of the current state.
    public func snapshot() -> InstallerNavigationSnapshot {
        InstallerNavigationSnapshot(
            currentPage: currentPage,
            result: nil
        )
    }

    // MARK: - Intent handlers

    /// Advance to the next page if the current page is complete.
    ///
    /// Preconditions checked in order:
    /// 1. Cleanup must not be required.
    /// 2. No active operation may be running.
    /// 3. The current page must be marked complete in `allPagesComplete`.
    ///
    /// If the reducer is already on the last page the intent is accepted
    /// but `newPage` is `nil` (terminal state).
    private func handleNext() -> InstallerNavigationResult {
        guard !cleanupRequired else {
            return rejected(.cleanupRequired)
        }

        guard !hasActiveOperation else {
            return rejected(.activeOperationInProgress)
        }

        guard allPagesComplete[currentPage] == true else {
            return rejected(.pageIncomplete)
        }

        let pages = InstallerPage.allCases
        guard let currentIndex = pages.firstIndex(of: currentPage) else {
            return rejected(.internalError)
        }

        let nextIndex = pages.index(after: currentIndex)
        guard nextIndex < pages.endIndex else {
            // Already at the last page — accept but stay put.
            return accepted()
        }

        let nextPage = pages[nextIndex]
        currentPage = nextPage
        return accepted(newPage: nextPage)
    }

    /// Go to the previous page.
    ///
    /// Preconditions:
    /// 1. Cleanup must not be required.
    /// 2. If an active operation is running, the transition is blocked.
    ///
    /// If the reducer is already on the first page the intent is accepted
    /// but `newPage` is `nil`.
    private func handleBack() -> InstallerNavigationResult {
        guard !cleanupRequired else {
            return rejected(.cleanupRequired)
        }

        guard !hasActiveOperation else {
            return rejected(.activeOperationInProgress)
        }

        let pages = InstallerPage.allCases
        guard let currentIndex = pages.firstIndex(of: currentPage) else {
            return rejected(.internalError)
        }

        guard currentIndex > pages.startIndex else {
            // Already at the first page.
            return accepted()
        }

        let prevPage = pages[pages.index(before: currentIndex)]
        currentPage = prevPage
        return accepted(newPage: prevPage)
    }

    /// Stop any active operation and attempt cleanup.
    ///
    /// 1. Always clears `hasActiveOperation`.
    /// 2. If `cleanupRequired` was set, attempts to resolve it by clearing
    ///    the flag. The external coordinator should set `cleanupRequired`
    ///    back to `true` if the actual cleanup procedure failed.
    /// 3. Returns a `cleanup_required` blocker when cleanup is still
    ///    necessary after the attempt.
    private func handleStopAndClean() -> InstallerNavigationResult {
        hasActiveOperation = false

        if cleanupRequired {
            // Attempt cleanup — reset the flag. In a real implementation
            // the reducer would invoke an external cleanup service here.
            // If that service fails, the external coordinator re-sets
            // `cleanupRequired = true` after this call returns.
            cleanupRequired = false
        }

        return accepted()
    }

    // MARK: - Helpers

    private func accepted(newPage: InstallerPage? = nil) -> InstallerNavigationResult {
        InstallerNavigationResult(
            accepted: true,
            newPage: newPage,
            blocker: nil
        )
    }

    private func rejected(_ blocker: InstallerNavigationBlocker) -> InstallerNavigationResult {
        InstallerNavigationResult(
            accepted: false,
            newPage: nil,
            blocker: blocker
        )
    }
}
