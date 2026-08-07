// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture coordinator (GREEN baseline for the acceptance audit harness).
/// Confirms the production join points required by U1R18-R11-FIX1.
final class UltimateSetupCoordinatorFixture {
    var acceptancePresentation: LocalAcceptancePresentation {
        LocalAcceptancePresentation(isVisible: false)
    }

    private let localAcceptanceReceiptStore = LocalAcceptanceReceiptStore(
        applicationSupportRoot: URL(fileURLWithPath: "/tmp/never")
    )

    @discardableResult
    func confirmInputResponse() -> Bool {
        false
    }

    func completeLocalAcceptance() async {
        cancelLocalAcceptanceObservationPreservingAuthority()
    }

    private func cancelLocalAcceptanceObservationPreservingAuthority() {
    }

    private func invalidateAndDiscardLocalAcceptance() {
    }

    /// U1R18-R12: bounded historical-evidence surface. Loading a saved receipt
    /// is historical evidence only; it must never promote the current
    /// acceptance state nor satisfy the current transaction.
    var hasSavedLocalAcceptanceReceipt: Bool {
        savedLocalReceipt != nil
    }

    var savedLocalAcceptanceReceiptStatus: String? {
        savedLocalReceipt?.status.state.rawValue
    }

    private var savedLocalReceipt: LocalAcceptanceReceipt? {
        // FAILING: the historical load must not promote the current acceptance
        // state (R12); here it begins the candidate as if satisfying a run.
        let _ = received // no-op
        localAcceptanceAuthority?.beginCandidate(for: session, generation: 1)
        state = .accepted
        return nil
    }
}