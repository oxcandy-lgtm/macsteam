// SPDX-License-Identifier: GPL-3.0-or-later

// MARK: - Audit Report

/// A report summarising the results of auditing all pages through all navigation intents.
public struct NavigationAuditReport: Codable, Sendable {
    /// Total number of pages in the installer flow.
    public let pageCount: Int

    /// True if every page accepted the `.back` intent.
    public let backPresentAll: Bool

    /// True if every page accepted the `.next` intent.
    /// (Pages are marked complete before testing.)
    public let nextPresentAll: Bool

    /// True if every page accepted the `.stopAndClean` intent.
    public let stopCleanPresentAll: Bool

    /// Pages that were unreachable — no intent succeeded when starting from this page.
    public let unreachablePages: [InstallerPage]

    /// Pages from which no forward navigation (`.next`) is possible,
    /// even when the page is marked complete.
    public let deadEnds: [InstallerPage]

    /// All unique blocker codes observed during the audit.
    public let blockerCodes: [String]
}

// MARK: - Audit Entry

struct PageAuditEntry: Sendable {
    let page: InstallerPage
    let backAccepted: Bool
    let nextAccepted: Bool
    let stopCleanAccepted: Bool
    let blockerCodes: [String]
}

// MARK: - Auditor

/// Iterates all installer pages, exercises every navigation intent on each,
/// and produces a ``NavigationAuditReport``.
///
/// Each page is tested in isolation by creating a fresh ``InstallerNavigationReducer``
/// whose starting page is set to the page under test. Every page is marked complete
/// before executing the `.next` intent so that the reducer's completion gate
/// does not block the test.
public struct InstallerNavigationAuditor: Sendable {

    public init() {}

    /// Run the full audit across all pages.
    /// - Returns: A ``NavigationAuditReport`` summarising the results.
    public func audit() async -> NavigationAuditReport {
        let pages = InstallerPage.allCases
        let entries = await withTaskGroup(of: PageAuditEntry.self) { group in
            for page in pages {
                group.addTask {
                    await auditPage(page)
                }
            }
            var results: [PageAuditEntry] = []
            for await entry in group {
                results.append(entry)
            }
            return results.sorted { $0.page.rawValue < $1.page.rawValue }
        }

        let pageCount = pages.count
        let backPresentAll = entries.allSatisfy { $0.backAccepted }
        let nextPresentAll = entries.allSatisfy { $0.nextAccepted }
        let stopCleanPresentAll = entries.allSatisfy { $0.stopCleanAccepted }
        let unreachablePages = entries
            .filter { !$0.backAccepted && !$0.nextAccepted && !$0.stopCleanAccepted }
            .map(\.page)
        let deadEnds = entries
            .filter { !$0.nextAccepted }
            .map(\.page)
        let allBlockerCodes = Set(entries.flatMap(\.blockerCodes)).sorted()

        return NavigationAuditReport(
            pageCount: pageCount,
            backPresentAll: backPresentAll,
            nextPresentAll: nextPresentAll,
            stopCleanPresentAll: stopCleanPresentAll,
            unreachablePages: unreachablePages,
            deadEnds: deadEnds,
            blockerCodes: allBlockerCodes
        )
    }

    // MARK: - Single-page audit

    private func auditPage(_ page: InstallerPage) async -> PageAuditEntry {
        var blockerCodes: [String] = []

        // --- test .back ---
        let backResult = await runIntent(page: page) { reducer in
            await reducer.send(intent: .back)
        }
        if let code = backResult.blocker?.code {
            blockerCodes.append(code)
        }

        // --- test .next (page is marked complete) ---
        let nextResult = await runIntent(page: page) { reducer in
            await reducer.send(intent: .next)
        }
        if let code = nextResult.blocker?.code {
            blockerCodes.append(code)
        }

        // --- test .stopAndClean ---
        let stopCleanResult = await runIntent(page: page) { reducer in
            await reducer.send(intent: .stopAndClean)
        }
        if let code = stopCleanResult.blocker?.code {
            blockerCodes.append(code)
        }

        return PageAuditEntry(
            page: page,
            backAccepted: backResult.accepted,
            nextAccepted: nextResult.accepted,
            stopCleanAccepted: stopCleanResult.accepted,
            blockerCodes: blockerCodes
        )
    }

    /// Create a fresh reducer starting at `page`, mark every page complete,
    /// and execute `operation`.
    private func runIntent(
        page: InstallerPage,
        operation: @escaping (isolated InstallerNavigationReducer) async -> InstallerNavigationResult
    ) async -> InstallerNavigationResult {
        let reducer = InstallerNavigationReducer(initialPage: page)
        // Mark all pages complete so .next doesn't fail on page_incomplete.
        for p in InstallerPage.allCases {
            await reducer.setPageComplete(p, true)
        }
        return await operation(reducer)
    }
}
