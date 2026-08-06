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
        }
    }

    func confirmInputResponse() -> Bool {
        false
    }
}