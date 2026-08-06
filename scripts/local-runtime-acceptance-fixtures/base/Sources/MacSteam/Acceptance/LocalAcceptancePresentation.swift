// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture presentation model (GREEN baseline for the acceptance audit harness).
struct LocalAcceptancePresentation {
    var isVisible: Bool = false
    var canConfirmMainMenu: Bool = false
    var canConfirmInputResponse: Bool = false
    var canComplete: Bool = false

    init(
        isVisible: Bool = false,
        canConfirmMainMenu: Bool = false,
        canConfirmInputResponse: Bool = false,
        canComplete: Bool = false
    ) {
        self.isVisible = isVisible
        self.canConfirmMainMenu = canConfirmMainMenu
        self.canConfirmInputResponse = canConfirmInputResponse
        self.canComplete = canComplete
    }
}