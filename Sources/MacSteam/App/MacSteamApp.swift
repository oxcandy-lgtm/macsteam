// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct MacSteamApp: App {
    @State private var coordinator = UltimateSetupCoordinator()
    @State private var gameManager = GameManager()

    var body: some Scene {
        WindowGroup {
            UltimateSetupView(coordinator: coordinator)
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacSteam") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: AppBrand.displayName,
                            .applicationVersion: "0.1.0"
                        ]
                    )
                }
            }
        }
    }
}
