// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// FAILING fixture: acceptance UI keyed off a launch result boolean, so it is
/// hidden after the launch result shows. This regresses the FIX1 requirement
/// that the acceptance panel survive / be driven by acceptance state.
struct CloverPitLaunchViewFixture: View {
    let acceptancePresentation: LocalAcceptancePresentation
    let launchResult: String

    var body: some View {
        Group {
            if !launchResult.isEmpty {
                Text(launchResult)
            }
        }
    }

    func confirmInputResponse() -> Bool {
        false
    }
}