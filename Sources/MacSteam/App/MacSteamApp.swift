// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared application context — single-owner for guard, coordinator, and the
/// control-plane mirror.
@MainActor
final class MacsTeamApplicationContext {
    let instanceGuard: AppInstanceGuard
    let coordinator: UltimateSetupCoordinator
    let controlPlaneMirror: ControlPlaneMirror

    init(instanceGuard: AppInstanceGuard, coordinator: UltimateSetupCoordinator) {
        self.instanceGuard = instanceGuard
        self.coordinator = coordinator
        // U1R18-R13-ACCEPTANCE4: the mirror is a production, always-on observer.
        // Started here (single owner) so state.json/events.ndjson exist for any
        // terminal client from app launch onward.
        let mirror = ControlPlaneMirror(coordinator: coordinator)
        self.controlPlaneMirror = mirror
        mirror.start()
    }
}

/// NSApplication delegate — lifecycle cleanup.
///
/// R5 Dock_Quit_COMPLETE_ZERO: the AppKit Dock-Quit / Cmd-Q path is driven
/// EXACTLY ONCE. A re-entrant `applicationShouldTerminate` (e.g. a second
/// Cmd-Q, or the Dock quit menu fired twice while cleanup is in flight) is a
/// true no-op: it returns `.terminateLater` and spawns NO second cleanup task,
/// so AppKit never receives a second `reply(...)` and the instance lock is
/// never released twice. `instanceGuard.release()` and the affirmative
/// `reply(true)` execute ONLY on a `.clean` (zero-residue) cleanup, and
/// `release()` strictly precedes `reply(true)`; on an incomplete cleanup AppKit
/// is told to abort the quit (`reply(false)`) with the lock retained for a safe
/// retry — cleanup-before-release-before-reply ordering is non-negotiable.
@MainActor
final class MacsTeamAppDelegate: NSObject, NSApplicationDelegate {
    static var shared: MacsTeamAppDelegate?
    var context: MacsTeamApplicationContext?

    /// Exact-once token: set on the first Dock-Quit invocation so a re-entrant
    /// call is a guaranteed no-op (no second task, no second reply, no second
    /// lock release). Read/written on MainActor only.
    private var terminationTransactionStarted = false

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
        guard let context else { return .terminateCancel }

        // Stop the mirror loop first: the final persisted state.json/events
        // must never be mutated after the termination transaction begins.
        context.controlPlaneMirror.stop()

        // Exact-once: a second Dock-Quit while the first cleanup is in flight
        // is a true no-op — never spawn a second cleanup Task or reply twice.
        if terminationTransactionStarted { return .terminateLater }
        terminationTransactionStarted = true

        Task { @MainActor in
            let result = await context.coordinator.stopAllForApplicationTermination()
            if result == .clean {
                // Zero-residue proven only here: remove the heartbeat (graceful
                // termination marker), release the instance lock, then affirm
                // the quit — release ALWAYS strictly precedes reply.
                context.controlPlaneMirror.removeHeartbeat()
                context.instanceGuard.release()
                sender.reply(toApplicationShouldTerminate: true)
        } else {
            // Incomplete cleanup: reset the exact-once token BEFORE the abort
            // reply so a re-entrant applicationShouldTerminate fired during the
            // abort cannot be shadowed by the no-op early return; the retry then
            // re-enters the full guard (fail-closed: missing context ->
            // .terminateCancel) and may drive a fresh cleanup transaction. The
            // lock is retained until a zero-residue proof is granted (no
            // release, no reply(true) without COMPLETE_ZERO). The mirror + command
            // consumer + heartbeat resume so the terminal never sees a false
            // `app_unresponsive` while the app survives the aborted quit.
            terminationTransactionStarted = false
            context.controlPlaneMirror.start()
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
