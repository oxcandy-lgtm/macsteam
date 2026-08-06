// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture coordinator (GREEN baseline for the acceptance audit harness).
/// Confirms the production join points required by U1R18-R11-FIX1.
final class UltimateSetupCoordinatorFixture {
    var acceptancePresentation: LocalAcceptancePresentation {
        LocalAcceptancePresentation(isVisible: false)
    }

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
}