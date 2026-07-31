// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The shared production navigation footer for all six installer surfaces.
///
/// A single presentation controls BOTH page identity and footer
/// availability: the footer is rendered only when
/// `presentation.hasCanonicalNavigation` is true, uses
/// `presentation.footerPage` as its page authority, and routes every intent
/// through `coordinator.send(intent)` — the single navigation authority.
///
/// Every surface (runtime / environment / steamInstaller / steamClient /
/// cloverPit / diagnostics) MUST use this helper (or satisfy all three of
/// those requirements in its own navigation body). The scanner verifies
/// this scope per surface.
@ViewBuilder
func canonicalNavigationFooter(
    presentation: UltimatePagePresentation,
    coordinator: UltimateSetupCoordinator
) -> some View {
    if presentation.hasCanonicalNavigation {
        InstallerNavigationFooter(
            validator: DefaultInstallerNavigationValidator(),
            currentPage: presentation.footerPage,
            onNavigate: { intent in
                await coordinator.send(intent)
            }
        )
    }
}
