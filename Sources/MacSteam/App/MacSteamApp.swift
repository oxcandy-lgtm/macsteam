// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared application context — single-owner for guard and coordinator.
@MainActor
final class MacsTeamApplicationContext {
    let instanceGuard: AppInstanceGuard
    let coordinator: UltimateSetupCoordinator

    init(instanceGuard: AppInstanceGuard, coordinator: UltimateSetupCoordinator) {
        self.instanceGuard = instanceGuard
        self.coordinator = coordinator
    }
}

/// NSApplication delegate — lifecycle cleanup.
@MainActor
final class MacsTeamAppDelegate: NSObject, NSApplicationDelegate {
    static var shared: MacsTeamAppDelegate?
    var context: MacsTeamApplicationContext?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set context from MacSteamApp's stored context
        if let ctx = MacSteamApp.sharedContext {
            self.context = ctx
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let context else { return .terminateNow }

        Task { @MainActor in
            let result = await context.coordinator.stopAllForApplicationTermination()
            if result == .clean {
                context.instanceGuard.release()
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

@main
struct MacSteamApp: App {
    static var sharedContext: MacsTeamApplicationContext?

    @State private var context: MacsTeamApplicationContext?

    @NSApplicationDelegateAdaptor(MacsTeamAppDelegate.self)
    private var appDelegate

    init() {
        let buildID = computeBuildID()
        let guard_ = AppInstanceGuard()

        do {
            let result = try guard_.acquireOrActivateExisting(buildID: buildID)
            switch result {
            case .primary:
                let coord = UltimateSetupCoordinator()
                let ctx = MacsTeamApplicationContext(instanceGuard: guard_, coordinator: coord)
                Self.sharedContext = ctx
                _context = State(initialValue: ctx)
            case .secondary(let holderPID):
                if let pid = holderPID, pid > 0, pid != ProcessInfo.processInfo.processIdentifier {
                    if let existing = NSRunningApplication(processIdentifier: pid) {
                        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    }
                }
                Darwin.exit(EXIT_SUCCESS)
            }
        } catch {
            fputs("MacsTeam: FATAL — lock acquisition failed: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        Window("MacsTeam", id: "main") {
            if let context {
                UltimateSetupView(coordinator: context.coordinator)
                    .frame(minWidth: 480, minHeight: 360)
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
            CommandGroup(replacing: .newItem) { }
        }
    }
}

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
