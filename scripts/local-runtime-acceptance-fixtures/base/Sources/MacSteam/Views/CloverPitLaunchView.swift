// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Fixture CloverPit launch view (GREEN baseline for the acceptance audit
/// harness). The acceptance UI must be reachable and independent of any launch
/// result, and must expose the input-response confirmation action.
struct CloverPitLaunchViewFixture: View {
    let acceptancePresentation: LocalAcceptancePresentation

    var body: some View {
        Group {
            if acceptancePresentation.isVisible {
                acceptancePanel
            }
        }
    }

    var acceptancePanel: some View {
        VStack {
            Button(action: { _ = confirmInputResponse() }) {
                Text("Confirm Input Response")
            }
            if let savedStatus = savedLocalAcceptanceReceiptStatus {
                // U1R18-R12: historical evidence only, never promotes current run.
                Row(detail: "Saved: \(savedStatus). Historical evidence only")
            }
        }
    }

    /// Bounded historical-evidence signal. Loading never promotes current state.
    var savedLocalAcceptanceReceiptStatus: String? {
        nil
    }

    func confirmInputResponse() -> Bool {
        false
    }
}

struct Row: View {
    let detail: String
    var body: some View { Text(detail) }
}