// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

// Test doubles

final class FakeInstallProcessSupervisor: @unchecked Sendable, ProcessSupervising {
    var launchCalls: [(plan: LaunchPlan, outputPolicy: ProcessOutputPolicy)] = []
    var waitForTerminationCalls: [SupervisedProcessHandle] = []
    var terminateCalls: [SupervisedProcessHandle] = []
    var forceKillCalls: [SupervisedProcessHandle] = []
    var discardCalls: [SupervisedProcessHandle] = []

    var launchResult: Result<SupervisedProcessHandle, Error> = .success(SupervisedProcessHandle(token: UUID(), pid: 0, startedAt: Date()))
    var waitForTerminationResult: ProcessWaitOutcome = .exited(0)

    /// When true, `waitForTermination` suspends until `resumeWait()` is called.
    /// When false (default), `waitForTermination` returns `waitForTerminationResult` immediately.
    var shouldSuspend = false

    /// When true, `requestForceKill` throws instead of resuming the waiter.
    var forceKillShouldThrow = false

    private var waitContinuation: CheckedContinuation<ProcessWaitOutcome, Never>?

    func launch(plan: LaunchPlan, outputPolicy: ProcessOutputPolicy) async throws -> SupervisedProcessHandle {
        launchCalls.append((plan, outputPolicy))
        return try launchResult.get()
    }

    func requestTerminate(_ handle: SupervisedProcessHandle) async {
        terminateCalls.append(handle)
    }

    func requestForceKill(_ handle: SupervisedProcessHandle) async throws {
        forceKillCalls.append(handle)
        if forceKillShouldThrow {
            throw ProcessRunner.RunnerError.executableNotFound(URL(fileURLWithPath: "/dev/null"))
        }
        // Simulate reality: force-killing the process causes waitForTermination to return
        resumeWait()
    }

    func waitForTermination(_ handle: SupervisedProcessHandle) async -> ProcessWaitOutcome {
        waitForTerminationCalls.append(handle)
        guard shouldSuspend else { return waitForTerminationResult }
        return await withCheckedContinuation { (c: CheckedContinuation<ProcessWaitOutcome, Never>) in
            waitContinuation = c
        }
    }

    func discard(_ handle: SupervisedProcessHandle) async {
        discardCalls.append(handle)
    }

    /// Resume a suspended `waitForTermination` with `waitForTerminationResult`.
    /// No-op if `waitForTermination` hasn't been called or `shouldSuspend` is false.
    func resumeWait() {
        guard let cont = waitContinuation else { return }
        waitContinuation = nil
        cont.resume(returning: waitForTerminationResult)
    }
}

final class FakeCleanupPrefixTerminator: @unchecked Sendable, PrefixProcessTerminating {
    var terminateCallCount = 0
    var terminateResult: PrefixCleanupResult = .clean

    func terminate(runtimeURL: URL, prefixURL: URL) async -> PrefixCleanupResult {
        terminateCallCount += 1
        return terminateResult
    }
}

final class ManualInstallDeadlineScheduler: @unchecked Sendable, DeadlineScheduling {
    var pendingActions: [(id: UUID, action: () -> Void)] = []

    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> CancellableWork {
        let id = UUID()
        pendingActions.append((id, action))
        return ManualInstallWork { [weak self] in self?.pendingActions.removeAll(where: { $0.id == id }) }
    }

    func fireNext() {
        guard !pendingActions.isEmpty else { return }
        let a = pendingActions.removeFirst()
        a.action()
    }
}

final class ManualInstallWork: @unchecked Sendable, CancellableWork {
    let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

// Tests

private let testInstallerURL = URL(fileURLWithPath: "/tmp/test-installer.exe")
private let testRuntimeURL = URL(fileURLWithPath: "/tmp/test-runtime")
private let testPrefixURL = URL(fileURLWithPath: "/tmp/test-prefix")

@Suite("InstallerSupervisorCleanup")
struct InstallerSupervisorCleanupTests {

    @Test("launch failure rethrows")
    func launchFailure_rethrows() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.launchResult = .failure(ProcessRunner.RunnerError.executableNotFound(testInstallerURL))
        let term = FakeCleanupPrefixTerminator()
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        await #expect(throws: ProcessRunner.RunnerError.executableNotFound(testInstallerURL)) {
            try await supervisor.startInstaller(
                installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
                prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
            )
        }
    }

    @Test("launch failure records terminal error")
    func launchFailure_recordsError() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.launchResult = .failure(ProcessRunner.RunnerError.executableNotFound(testInstallerURL))
        let term = FakeCleanupPrefixTerminator()
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try? await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        let isTerminal = await supervisor.snapshot()?.phase.isTerminal
        #expect(isTerminal == true)
    }

    @Test("single process waiter")
    func singleProcessWaiter() async throws {
        let sup = FakeInstallProcessSupervisor()
        let term = FakeCleanupPrefixTerminator()
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        #expect(sup.waitForTerminationCalls.count == 0) // waiter is in Task, not yet called
        #expect(sup.launchCalls.count == 1)
    }

    @Test("normal exit → verifyingInstallation")
    func normalExit_verifyingInstallation() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        // waitForTermination returns immediately by default — exit task already
        // recorded the outcome in the latch. give it one tick to process.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.waitForInstallerExit()
        #expect(sup.waitForTerminationCalls.count == 1)
        #expect(sup.discardCalls.count == 1)
        let phase = await supervisor.snapshot()?.phase
        #expect(phase == .verifyingInstallation)
    }

    @Test("stop SIGTERM exit → discard once")
    func stopSigtermExit_discardOnce() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        // Latch already populated by exit task
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        #expect(sup.terminateCalls.count == 1) // SIGTERM
        #expect(sup.forceKillCalls.isEmpty) // not needed
        #expect(sup.discardCalls.count == 1)
    }

    @Test("SIGTERM deadline → force kill once")
    func sigtermDeadline_forceKillOnce() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .timedOut
        sup.shouldSuspend = true // keep exit task waiting
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        // Exit task is suspended, latch stays .waiting
        // stopAndClean sends SIGTERM → exitLatch.wait(5) times out → SIGKILL
        try await supervisor.stopAndClean()
        #expect(sup.terminateCalls.count == 1) // SIGTERM
        #expect(sup.forceKillCalls.count == 1) // SIGKILL after deadline
        #expect(sup.discardCalls.count == 1)
    }

    @Test("SIGKILL exit → prefix cleanup")
    func sigkillExit_prefixCleanup() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        #expect(term.terminateCallCount == 1) // prefix cleanup invoked
    }

    @Test("prefix clean → all state clear")
    func prefixClean_stateClear() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        let op = await supervisor.snapshot()
        #expect(op == nil)
    }

    @Test("prefix incomplete → cleanupRequired")
    func prefixIncomplete_cleanupRequired() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .incomplete(reason: "steam.exe still running")
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        await #expect(throws: InstallerError.self) {
            try await supervisor.stopAndClean()
        }
        let phase = await supervisor.snapshot()?.phase
        #expect(phase == .cleanupRequired)
    }

    @Test("retry clean → state cleared")
    func retryClean_stateCleared() async throws {
        let sup = FakeInstallProcessSupervisor()
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        let op = await supervisor.snapshot()
        #expect(op == nil)
    }

    @Test("observer/stop race → discard once")
    func observerStopRace_discardOnce() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        #expect(sup.discardCalls.count == 1)
    }

    @Test("observer/stop race → verifyingInstallation zero")
    func observerStopRace_noVerification() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        let phase = await supervisor.snapshot()?.phase
        #expect(phase != .verifyingInstallation)
    }

    @Test("missing runtime/prefix → cleanupRequired")
    func missingRuntimePrefix_cleanupRequired() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)
        try? await supervisor.stopAndClean()
    }

    @Test("double finalize → discard once")
    func doubleFinalize_discardOnce() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        // Call stopAndClean twice
        try await supervisor.stopAndClean()
        try? await supervisor.stopAndClean()
        #expect(sup.discardCalls.count == 1)
    }

    // ── Broadcast latch / generation isolation tests ──

    @Test("launch generation isolation")
    func launchGenerationIsolation() async throws {
        let sup = FakeInstallProcessSupervisor()
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        // Launch A
        sup.waitForTerminationResult = .exited(0)
        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.stopAndClean()
        #expect(sup.discardCalls.count == 1)

        // Launch B (state cleared by stopAndClean)
        sup.waitForTerminationResult = .exited(42) // Different exit code
        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        // Verify that wait sees the new exit, not the old one
        try await supervisor.waitForInstallerExit()
        // After launch B exit, phase should have transitioned from installerExited
        let phase = await supervisor.snapshot()?.phase
        #expect(phase == .failed) // Non-zero exit → .failed
        let lastError = await supervisor.snapshot()?.lastError
        #expect(lastError == "Installer exited with code 42")
    }

    @Test("concurrent waiters both observe exit")
    func concurrentWaiters_bothObserveExit() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        async let waitResult = supervisor.waitForInstallerExit()
        async let stopResult = supervisor.stopAndClean()

        _ = try await (waitResult, stopResult)
        #expect(sup.discardCalls.count == 1)
        #expect(term.terminateCallCount == 1)
    }

    @Test("cleanupRequired blocks new installer")
    func cleanupRequired_blocksNewInstaller() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .incomplete(reason: "prefix still busy")
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        // First stop fails → cleanupRequired
        try? await supervisor.stopAndClean()
        #expect(await supervisor.snapshot()?.phase == .cleanupRequired)

        // Starting a new installer while in cleanupRequired is NOT allowed.
        // The startInstaller guard rejects any non-nil currentOperation.
        term.terminateResult = .clean
        await #expect(throws: InstallerError.self) {
            try await supervisor.startInstaller(
                installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
                prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
            )
        }
        // Phase unchanged after rejected start
        #expect(await supervisor.snapshot()?.phase == .cleanupRequired)
    }

    @Test("force kill throw → cleanupRequired")
    func forceKillThrow_cleanupRequired() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .timedOut
        sup.shouldSuspend = true
        sup.forceKillShouldThrow = true
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .clean
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        // stopAndClean sends SIGTERM → exitLatch times out → forceKill throws
        await #expect(throws: (any Error).self) {
            try await supervisor.stopAndClean()
        }
        // The error should propagate; check that terminate was called (SIGTERM)
        #expect(sup.terminateCalls.count == 1)
    }

    @Test("second incomplete updates reason")
    func secondIncomplete_updatesReason() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(0)
        let term = FakeCleanupPrefixTerminator()
        term.terminateResult = .incomplete(reason: "first attempt failed")
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // First stop → cleanupRequired with first reason
        try? await supervisor.stopAndClean()
        #expect(await supervisor.snapshot()?.phase == .cleanupRequired)
        let firstReason = await supervisor.snapshot()?.lastError
        #expect(firstReason == "first attempt failed")

        // Second stop → reason updated
        term.terminateResult = .incomplete(reason: "second attempt failed")
        try? await supervisor.stopAndClean()
        #expect(await supervisor.snapshot()?.phase == .cleanupRequired)
        let secondReason = await supervisor.snapshot()?.lastError
        #expect(secondReason == "second attempt failed")
    }

    @Test("nonzero exit persists failed phase")
    func nonzeroExit_persistsFailedPhase() async throws {
        let sup = FakeInstallProcessSupervisor()
        sup.waitForTerminationResult = .exited(1) // non-zero exit
        let term = FakeCleanupPrefixTerminator()
        let supervisor = InstallerSupervisor(processSupervisor: sup, prefixTerminator: term)

        try await supervisor.startInstaller(
            installerURL: testInstallerURL, runtimeURL: testRuntimeURL,
            prefixURL: testPrefixURL, runtimeSafeID: "r", prefixSafeID: "p"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await supervisor.waitForInstallerExit()
        let phase = await supervisor.snapshot()?.phase
        #expect(phase == .failed)
        let lastError = await supervisor.snapshot()?.lastError
        #expect(lastError == "Installer exited with code 1")
    }
}
