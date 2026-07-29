// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// NSApplication delegate that hooks into lifecycle events for session cleanup.
@MainActor
final class MacsTeamAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: UltimateSetupCoordinator?
    private let guardActor = AppInstanceGuard()
    private let buildID: String

    override init() {
        // Compute build ID from executable hash
        var bid = "unknown"
        if let execURL = Bundle.main.executableURL,
           let data = try? Data(contentsOf: execURL) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["shasum", "-a", "256"]
            let inpPipe = Pipe()
            process.standardInput = inpPipe
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()
            try? process.run()
            inpPipe.fileHandleForWriting.write(data)
            inpPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            bid = String(output.prefix(12))
        }
        self.buildID = bid
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let acquired = try await guardActor.acquire(buildID: buildID)
                if !acquired {
                    // Another instance holds the lock — activate it and exit
                    let pid = try? await guardActor.readHolderPID()
                    if let pid, let app = NSRunningApplication(processIdentifier: pid),
                       app != NSRunningApplication.current {
                        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    }
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                // Lock failure — log but continue (degraded mode)
                NSLog("MacsTeam: AppInstanceGuard failed: \(error.localizedDescription)")
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }

        // Release lock on exit
        Task { @MainActor in
            _ = try? await self.guardActor.release()
        }

        if coordinator.hasActiveSteamSetupSession {
            Task { @MainActor in
                let success = await coordinator.stopSteamSetupForTermination()
                sender.reply(toApplicationShouldTerminate: success)
            }
            return .terminateLater
        }

        return .terminateNow
    }
}

@main
struct MacSteamApp: App {
    @State private var coordinator = UltimateSetupCoordinator()

    @NSApplicationDelegateAdaptor(MacsTeamAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Window("MacsTeam", id: "main") {
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
            // Remove New Window command
            CommandGroup(replacing: .newItem) { }
        }
    }
}
