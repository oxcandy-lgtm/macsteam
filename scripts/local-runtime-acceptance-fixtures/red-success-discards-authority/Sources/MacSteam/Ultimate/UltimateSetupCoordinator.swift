// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// FAILING fixture: on a successful acceptance the coordinator invalidates and
/// discards the authority instead of preserving it (regression of FIX1
/// split-cancel-vs-invalidate).
final class UltimateSetupCoordinatorFixture {
    var acceptancePresentation: LocalAcceptancePresentation {
        LocalAcceptancePresentation(isVisible: false)
    }

    @discardableResult
    func confirmInputResponse() -> Bool {
        false
    }

    func completeLocalAcceptance() async {
        let _ = await complete()
    }

    private func complete() async -> Bool {
        true
    }

    private func invalidateAndDiscardLocalAcceptance() {
    }
}