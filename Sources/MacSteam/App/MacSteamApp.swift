// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// NSApplication delegate that hooks into lifecycle events for session cleanup.
@MainActor
final class MacsTeamAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: UltimateSetupCoordinator?
    let instanceGuard: AppInstanceGuard

    override init() {
        self.instanceGuard = AppInstanceGuard()
        super.init()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }

        if coordinator.hasActiveSteamSetupSession {
            Task { @MainActor in
                let success = await coordinator.stopSteamSetupForTermination()
                // Release lock only after clean shutdown
                self.instanceGuard.release()
                sender.reply(toApplicationShouldTerminate: success)
            }
            return .terminateLater
        }

        // No active session — release lock and exit
        instanceGuard.release()
        return .terminateNow
    }
}

@main
struct MacSteamApp: App {
    @State private var coordinator = UltimateSetupCoordinator()

    @NSApplicationDelegateAdaptor(MacsTeamAppDelegate.self)
    private var appDelegate

    init() {
        // Acquire the single-instance lock BEFORE any UI is created.
        // Must be synchronous — fail-closed on I/O error.
        let guardActor = AppInstanceGuard()
        let buildID = computeBuildID()
        do {
            let result = try guardActor.acquireOrActivateExisting(buildID: buildID)
            switch result {
            case .primary:
                break // proceed
            case .secondary(let holderPID):
                // Activate the existing instance and exit this one
                let app = NSRunningApplication(processIdentifier: holderPID)
                if holderPID > 0, holderPID != ProcessInfo.processInfo.processIdentifier,
                   let existing = app {
                    existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
                // Can't throw from init to exit — use fatalError for controlled exit
                // but first let the runloop finish briefly
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                // Fall through — terminate will be called on runloop
            }
        } catch {
            // Lock I/O failure — must not proceed under any circumstances
            // Use NSLog for diagnostics before exiting
            NSLog("MacsTeam: FATAL — lock acquisition failed: \(error.localizedDescription)")
            // Exit via terminate to allow proper cleanup
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

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

/// Compute a short build ID from the executable hash.
private func computeBuildID() -> String {
    guard let execURL = Bundle.main.executableURL,
          let data = try? Data(contentsOf: execURL) else { return "unknown" }
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
    return String(output.prefix(12))
}
