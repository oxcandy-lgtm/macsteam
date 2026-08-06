// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// FAILING fixture: dropped the input-response confirmation action from the
/// CloverPit UI join point.
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
            Button(action: {}) {
                Text("Confirm Input Response")
            }
        }
    }
}