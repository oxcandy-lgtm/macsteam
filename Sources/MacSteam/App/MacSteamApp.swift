// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// NSApplication delegate that hooks into lifecycle events for session cleanup.
@MainActor
final class MacsTeamAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: UltimateSetupCoordinator?

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.hasActiveSteamSetupSession else {
            return .terminateNow
        }

        Task { @MainActor in
            let success = await coordinator.stopSteamSetupForTermination()
            sender.reply(toApplicationShouldTerminate: success)
        }

        return .terminateLater
    }
}

@main
struct MacSteamApp: App {
    @State private var coordinator = UltimateSetupCoordinator()

    @NSApplicationDelegateAdaptor(MacsTeamAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            UltimateSetupView(coordinator: coordinator)
                .frame(minWidth: 480, minHeight: 360)
                .onAppear {
                    appDelegate.coordinator = coordinator
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppBrand.displayName)") {
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
