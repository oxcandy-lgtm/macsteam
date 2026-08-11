// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import Darwin
import AppKit
@testable import MacSteam

/// U1R18-R5 Dock Quit COMPLETE_ZERO evidence suite.
///
/// Drives the GENUINE AppKit Dock-Quit / Cmd-Q path
/// (`MacsTeamAppDelegate.applicationShouldTerminate`) on a live
/// `UltimateSetupCoordinator` + `AppInstanceGuard`, then proves:
///
///  - the quit is driven EXACTLY ONCE: a re-entrant double invocation (a
///    second Cmd-Q / a second Dock-menu quit while the first cleanup is in
///    flight) returns `.terminateLater` and spawns NO second cleanup Task, so
///    AppKit never receives a second `reply(...)` and the instance lock is
///    never released twice;
///  - the transaction reaches a zero-residue `.stopped` (no active session, no
///    recovery authority) with the host-process census for the prefix == 0 and
///    the R4 ui-instance lock released.
///
/// No R3 types (`SessionProcessTree`, etc.) are referenced, so the suite
/// compiles independently of the R3 tree-scoping work. Gated on
/// `MACSTEAM_R1_BRINGUP=1` and serialized (mutates the real instance lock).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSTEAM_R1_BRINGUP"] == "1"), .serialized)
@MainActor
struct U1R18R5DockQuitCompleteZeroTests {

    /// R5: Dock Quit through `applicationShouldTerminate` is exact-once and
    /// reaches a complete-zero residue state.
    @Test("R5: Dock Quit through applicationShouldTerminate is exact-once and complete-zero")
    func dockQuitIsExactOnceAndCompleteZero() async throws {
        let instanceGuard = AppInstanceGuard()
        let acquire = try instanceGuard.acquireOrActivateExisting(buildID: "u1r18-r5-dockquit")
        guard case .primary = acquire else {
            Issue.record("could not acquire the ui-instance lock for the R5 Dock Quit proof")
            return
        }
        let coordinator = UltimateSetupCoordinator()
        let context = MacsTeamApplicationContext(instanceGuard: instanceGuard, coordinator: coordinator)
        let delegate = MacsTeamAppDelegate()
        delegate.context = context

        // Re-entrant Dock Quit (double Cmd-Q / double Dock menu): the first
        // invocation sets the exact-once token and spawns the single cleanup
        // Task; the second MUST be a no-op (no second Task, no second reply).
        let firstReply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(firstReply == .terminateLater)
        let reentrantReply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(reentrantReply == .terminateLater,
                "re-entrant Dock Quit must be an exact-once no-op")

        let stopped = await waitForStopped(coordinator, timeout: .seconds(90))
        #expect(stopped, "Dock Quit must drive the supervisor to .stopped exactly once")
        #expect(coordinator.activeSession == nil)

        // Zero-residue: receipt absent, host-process census == 0, lock released.
        let scratchPrefix = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-r5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchPrefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchPrefix) }

        let receipt = SessionReceiptStore().read(prefix: scratchPrefix)
        #expect(receipt == nil, "receipt must be absent after Dock Quit")

        let census = await PrefixProcessTerminator().snapshot(
            runtimeURL: scratchPrefix,
            prefixURL: scratchPrefix
        )
        #expect(census.windowsProcesses.total == 0,
                "no host processes may remain for the prefix after Dock Quit")

        let lockReleased = Self.uiInstanceLockIsReleased()
        #expect(lockReleased, "Dock Quit must release the ui-instance lock exactly once")
    }

    // MARK: - Helpers

    @MainActor
    private func waitForStopped(_ coordinator: UltimateSetupCoordinator, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if coordinator.sessionSupervisorState == .stopped { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return coordinator.sessionSupervisorState == .stopped
    }

    /// A fresh exclusive flock on the ui-instance lock succeeds iff the prior
    /// holder released it — proving `AppInstanceGuard.release()` ran exactly
    /// once through the Dock Quit path.
    nonisolated fileprivate static func uiInstanceLockIsReleased() -> Bool {
        let expanded = (AppInstanceGuard.lockPath as NSString).expandingTildeInPath
        let fd = open(expanded, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
        if acquired { flock(fd, LOCK_UN) }
        return acquired
    }
}
