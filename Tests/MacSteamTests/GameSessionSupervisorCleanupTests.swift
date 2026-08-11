// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

/// Inert window provider so the monitor never touches WindowServer.
private struct CleanupEmptyWindowProvider: WindowInfoProviding {
    func snapshot() throws -> [WindowInfo] { [] }
}

/// A no-op wineserver runtime (probes terminate immediately).
private struct CleanupFakeRuntime: WineRuntimeControl {
    var wineserverExecutable: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        ["WINEPREFIX": prefix.path]
    }
}

/// A no-op wineserver runtime (probes terminate immediately).
private struct Fix7WineRuntime: WineRuntimeControl {
    var wineserverExecutable: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        ["WINEPREFIX": prefix.path]
    }
}

/// Counting, scriptable process-control fake. Every cleanup call is tallied so
/// the invariants (reap-before-discard, halt-on-unconfirmed, no re-run on
/// retry) are asserted behaviorally — not by reading comments or identifiers.
private actor FakeCleanupProcesses: CleanupProcessControlling {
    private(set) var terminateCount = 0
    private(set) var forceKillCount = 0
    private(set) var discardCount = 0
    private(set) var waitCount = 0
    var reapTimesOut: Bool

    init(reapTimesOut: Bool = false) { self.reapTimesOut = reapTimesOut }

    func setReapTimesOut(_ value: Bool) { reapTimesOut = value }

    func requestTerminate(_ handle: SupervisedProcessHandle) async { terminateCount += 1 }
    func requestForceKill(_ handle: SupervisedProcessHandle) async throws { forceKillCount += 1 }
    func waitForExit(_ handle: SupervisedProcessHandle, timeout: Duration) async -> ProcessWaitOutcome {
        waitCount += 1
        return reapTimesOut ? .timedOut : .exited(0)
    }
    func discard(_ handle: SupervisedProcessHandle) async { discardCount += 1 }
}

/// Counting, scriptable wineserver-control fake.
private actor FakeCleanupWineserver: CleanupWineServerControlling {
    private(set) var shutdownCount = 0
    private(set) var isRunningCount = 0
    var shutdownThrows: Bool
    var stillRunning: Bool

    init(shutdownThrows: Bool = false, stillRunning: Bool = false) {
        self.shutdownThrows = shutdownThrows
        self.stillRunning = stillRunning
    }

    func setStillRunning(_ value: Bool) { stillRunning = value }
    func setShutdownThrows(_ value: Bool) { shutdownThrows = value }

    func shutdownPrefix(runtime: any WineRuntimeControl, prefix: URL, waitSeconds: Int) async throws -> Bool {
        shutdownCount += 1
        if shutdownThrows { throw WineServerError.timeout("fake shutdown failure") }
        return true
    }
    func isRunning(prefix: URL, runtime: any WineRuntimeControl) async throws -> Bool {
        isRunningCount += 1
        return stillRunning
    }
}

@MainActor
private func makeLockedPrefix() throws -> (URL, SessionLock) {
    let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
    let dir = root.appendingPathComponent("ms-u1r18-fix6-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let lock = try SessionLock(prefix: dir)
    _ = try lock.acquire()
    return (dir, lock)
}

private func fakeHandle() -> SupervisedProcessHandle {
    SupervisedProcessHandle(token: UUID(), pid: 999_999, startedAt: Date())
}

@MainActor
private func makeAuthority(prefix: URL, lock: SessionLock) -> RecoveryCleanupAuthority {
    RecoveryCleanupAuthority(
        processHandle: fakeHandle(),
        sessionLock: lock,
        runtimeControl: LiveRuntimeControl(control: CleanupFakeRuntime()),
        prefix: prefix
    )
}

/// U1R18-R4-FIX6 behavioral proof suite for the stored recovery-cleanup
/// transaction. Drives the real `GameSessionSupervisor.stop`/`forceStop` route
/// with counting fakes and a REAL prefix lock, asserting the side-effect counts
/// and persisted authority progress directly.
@MainActor
struct GameSessionSupervisorCleanupTests {

    private func makeSupervisor(
        _ procs: FakeCleanupProcesses,
        _ wine: FakeCleanupWineserver
    ) -> GameSessionSupervisor {
        GameSessionSupervisor(
            windowProvider: CleanupEmptyWindowProvider(),
            cleanupProcesses: procs,
            cleanupWineserver: wine
        )
    }

    // 1. reap unconfirmed → discard / wineserver / lock-release / authority-clear
    //    all execute zero times.
    @Test("reap unconfirmed halts every subsequent phase")
    func reapUnconfirmedHaltsAllSubsequentPhases() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: true)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do {
            try await sup.forceStop()
            Issue.record("expected forceStop to throw on unconfirmed reap")
        } catch {}

        #expect(await procs.discardCount == 0)
        #expect(await wine.shutdownCount == 0)
        #expect(await wine.isRunningCount == 0)
        #expect(lock.isHeld, "lock must NOT be released on unconfirmed reap")
        #expect(sup.needsRecovery)
        #expect(sup.recoveryCleanupForTesting != nil, "authority must be retained")
    }

    // 2. second-wait timeout keeps the authority (and its progress) for retry.
    @Test("second-wait timeout retains the authority")
    func secondWaitTimeoutKeepsAuthority() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: true)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}

        let retained = sup.recoveryCleanupForTesting
        #expect(retained != nil)
        #expect(retained?.reapConfirmed == false)
        #expect(retained?.processDiscarded == false)
        #expect(await procs.forceKillCount == 1, "SIGKILL was attempted before the second wait")
        #expect(sup.needsRecovery)
    }

    // 3. wineserver still-running after a confirmed reap+discard retains the
    //    reap/discard progress and keeps the lock.
    @Test("wineserver failure retains reap+discard progress")
    func wineserverFailureRetainsReapDiscardProgress() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver(stillRunning: true)
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}

        #expect(await procs.discardCount == 1)
        let retained = sup.recoveryCleanupForTesting
        #expect(retained?.reapConfirmed == true)
        #expect(retained?.processDiscarded == true)
        #expect(retained?.wineserverShutdown == false)
        #expect(lock.isHeld, "lock must NOT be released before wineserver confirms")
        #expect(sup.needsRecovery)
    }

    // 4. wineserver shutdownPrefix throwing retains reap/discard progress.
    @Test("wineserver shutdown throw retains reap+discard progress")
    func shutdownThrowRetainsProgress() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver(shutdownThrows: true)
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}

        #expect(await procs.discardCount == 1)
        let retained = sup.recoveryCleanupForTesting
        #expect(retained?.processDiscarded == true)
        #expect(retained?.wineserverShutdown == false)
        #expect(lock.isHeld)
    }

    // 5. retry after a wineserver failure does NOT re-run TERM/KILL/discard.
    @Test("retry does not re-run confirmed TERM/KILL/discard")
    func retryDoesNotRerunConfirmedSteps() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver(stillRunning: true)
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}
        #expect(await procs.terminateCount == 1)
        #expect(await procs.discardCount == 1)

        await wine.setStillRunning(false)
        try await sup.forceStop()

        #expect(await procs.terminateCount == 1, "TERM must not re-run on retry")
        #expect(await procs.forceKillCount == 0, "KILL must not run once reap confirmed")
        #expect(await procs.discardCount == 1, "discard must not re-run on retry")
        #expect(sup.state == .stopped)
        #expect(!lock.isHeld, "lock released exactly once at the terminal step")
        #expect(sup.recoveryCleanupForTesting == nil)
    }

    // 6. retry after an unconfirmed reap RE-CONTENDS the reap (not yet discarded).
    @Test("retry after unconfirmed reap re-contends the reap")
    func retryAfterUnconfirmedRecontends() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: true)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}
        #expect(await procs.discardCount == 0)

        // The process becomes reapable; the retry must re-attempt TERM and reap.
        await procs.setReapTimesOut(false)
        try await sup.forceStop()

        #expect(await procs.terminateCount == 2, "reap re-contended on retry")
        #expect(await procs.discardCount == 1, "discard happens once the reap confirms")
        #expect(sup.state == .stopped)
    }

    // 7. activeSession == nil still cleans up from the retained authority.
    @Test("cleanup proceeds from authority when activeSession is nil")
    func cleanupFromAuthorityWithNilSession() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        #expect(sup.activeSession == nil)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        try await sup.forceStop()   // must NOT no-op on nil activeSession

        #expect(sup.state == .stopped)
        #expect(await procs.discardCount == 1)
        #expect(!lock.isHeld)
    }

    // 8. TERM success drives the full ordered transaction to stopped.
    @Test("TERM success runs the full transaction to stopped")
    func termSuccessFullCleanup() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        try await sup.forceStop()

        #expect(await procs.terminateCount == 1)
        #expect(await procs.forceKillCount == 0, "no KILL when TERM reaps")
        #expect(await procs.discardCount == 1)
        #expect(await wine.shutdownCount == 1)
        #expect(await wine.isRunningCount == 1)
        #expect(!lock.isHeld)
        #expect(sup.state == .stopped)
        #expect(sup.recoveryCleanupForTesting == nil)
    }

    // 9. discard happens only after a confirmed reap (never before).
    @Test("discard only after confirmed reap")
    func discardOnlyAfterConfirmed() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: true)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}
        #expect(await procs.discardCount == 0, "unconfirmed reap must never discard")
    }

    // 10. wineserver is confirmed stopped before the lock is released.
    @Test("lock not released while wineserver still running")
    func wineserverConfirmedBeforeLockRelease() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver(stillRunning: true)
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}
        #expect(lock.isHeld, "lock must stay held while wineserver is unconfirmed")
        #expect(await wine.isRunningCount == 1)
    }

    // 11. the authority is never nil while recovery is required.
    @Test("authority never nil while recovery required")
    func authorityNeverNilWhileRecovery() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { lock.release(); try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: true)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        #expect(sup.needsRecovery)
        #expect(sup.recoveryCleanupForTesting != nil)
        do { try await sup.forceStop() } catch {}
        #expect(sup.needsRecovery)
        #expect(sup.recoveryCleanupForTesting != nil, "failed retry must not nil the authority")
    }

    // 12. receipt/bookkeeping removed only at the terminal step.
    @Test("receipt removed only at terminal")
    func receiptRemovedOnlyAtTerminal() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let store = SessionReceiptStore()
        let session = GameSession(
            sessionID: UUID(), recipeID: "r", runtimeID: "rt",
            prefixRoot: prefix, rootPID: 1, startedAt: Date(), purpose: .game
        )
        try store.write(session: session, state: .runningUnknown)

        let procs = FakeCleanupProcesses(reapTimesOut: true)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        do { try await sup.forceStop() } catch {}
        #expect(store.read(prefix: prefix) != nil, "receipt must survive an unconfirmed cleanup")

        await procs.setReapTimesOut(false)
        try await sup.forceStop()
        #expect(store.read(prefix: prefix) == nil, "receipt removed only at terminal")
    }

    // 13. the authority-owned lock is the one released at terminal.
    @Test("authority-owned lock released at terminal")
    func authorityOwnedLockReleased() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        #expect(lock.isHeld)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        try await sup.forceStop()
        #expect(!lock.isHeld, "the authority-owned lock is released at terminal")
    }

    // 14. a completed cleanup is idempotent: a second stop is a no-op and the
    //     lock is never released twice through a re-entered transaction.
    @Test("completed cleanup is idempotent")
    func completedCleanupIdempotent() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        try await sup.forceStop()
        #expect(sup.state == .stopped)
        #expect(await procs.discardCount == 1)

        try await sup.forceStop()   // no authority left → no-op
        #expect(await procs.discardCount == 1, "no re-entry after completion")
        #expect(await procs.terminateCount == 1)
    }

    // MARK: - FIX7 state-idempotence

    // stop() re-run after completion: .stopped preserved, every cleanup side
    // effect stays at zero.
    @Test("stop re-run after completion is a zero-side-effect no-op")
    func stopReRunAfterCompletionIsNoOp() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        try await sup.stop()
        #expect(sup.state == .stopped)
        let term = await procs.terminateCount
        let discard = await procs.discardCount
        let ws = await wine.shutdownCount

        try await sup.stop()
        #expect(sup.state == .stopped, "second stop must preserve .stopped")
        #expect(await procs.terminateCount == term, "no TERM on re-run")
        #expect(await procs.discardCount == discard, "no discard on re-run")
        #expect(await wine.shutdownCount == ws, "no wineserver call on re-run")
        #expect(sup.recoveryCleanupForTesting == nil)
    }

    // forceStop() re-run after completion: .stopped preserved, every cleanup
    // side effect stays at zero.
    @Test("forceStop re-run after completion is a zero-side-effect no-op")
    func forceStopReRunAfterCompletionIsNoOp() async throws {
        let (prefix, lock) = try makeLockedPrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let procs = FakeCleanupProcesses(reapTimesOut: false)
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        sup.installRecoveryAuthorityForTesting(makeAuthority(prefix: prefix, lock: lock))

        try await sup.forceStop()
        #expect(sup.state == .stopped)
        let term = await procs.terminateCount
        let discard = await procs.discardCount
        let ws = await wine.shutdownCount

        try await sup.forceStop()
        #expect(sup.state == .stopped, "second forceStop must preserve .stopped")
        #expect(await procs.terminateCount == term, "no TERM on re-run")
        #expect(await procs.discardCount == discard, "no discard on re-run")
        #expect(await wine.shutdownCount == ws, "no wineserver call on re-run")
    }

    // In .idle, stop()/forceStop() preserve .idle and perform no cleanup.
    @Test("idle state preserved by stop/forceStop with zero side effects")
    func idleStopPreservedWithZeroSideEffects() async throws {
        let procs = FakeCleanupProcesses()
        let wine = FakeCleanupWineserver()
        let sup = makeSupervisor(procs, wine)
        #expect(sup.state == .idle)

        try await sup.stop()
        #expect(sup.state == .idle, "idle must be preserved by stop()")
        #expect(sup.recoveryCleanupForTesting == nil)

        try await sup.forceStop()
        #expect(sup.state == .idle, "idle must be preserved by forceStop()")
        #expect(await procs.terminateCount == 0)
        #expect(await procs.discardCount == 0)
        #expect(await wine.shutdownCount == 0)
    }

    // After idempotent cleanup, the launch gate is reachable (no stale
    // `.stopping`) and a real session can be launched again.
    @Test("launch reachable after idempotent cleanup")
    func launchReachableAfterIdempotentCleanup() async throws {
        let prefixDir = try makeTempPrefix()
        defer {
            SessionReceiptStore().remove(prefix: prefixDir)
            try? FileManager.default.removeItem(at: prefixDir)
        }
        let sup = GameSessionSupervisor(windowProvider: CleanupEmptyWindowProvider())

        // First real session.
        let plan = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["3"],
            mode: .supervisedSession
        )
        _ = try await sup.launch(
            plan: plan,
            runtimeControl: Fix7WineRuntime(),
            prefixRoot: prefixDir,
            recipeID: "cloverpit",
            runtimeID: "fix7",
            purpose: .game
        )
        #expect(sup.state == .runningUnknown)

        // Cleanup to completion.
        try await sup.stop()
        #expect(sup.state == .stopped, "first stop completes the transaction")

        // Re-running stop must not strand the supervisor in .stopping.
        try await sup.stop()
        #expect(sup.state == .stopped, "second stop preserves .stopped (no stale .stopping)")

        // The launch gate accepts a completed supervisor.
        _ = try await sup.launch(
            plan: plan,
            runtimeControl: Fix7WineRuntime(),
            prefixRoot: prefixDir,
            recipeID: "cloverpit",
            runtimeID: "fix7b",
            purpose: .game
        )
        #expect(sup.state == .runningUnknown, "launch gate is reachable after cleanup")
        try await sup.forceStop()
    }

    @MainActor
    private func makeTempPrefix() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
        let dir = root.appendingPathComponent("ms-u1r18-fix7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }
}
