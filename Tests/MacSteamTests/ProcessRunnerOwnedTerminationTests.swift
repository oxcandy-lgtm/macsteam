// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

// MARK: - Test doubles

final class FakeIdentityProvider: @unchecked Sendable, ProcessIdentityProviding {
    var callCount = 0
    var responses: [Result<ProcessIdentitySnapshot, Error>] = []

    func identity(forPID pid: Int32) throws -> ProcessIdentitySnapshot {
        callCount += 1
        if callCount <= responses.count {
            return try responses[callCount - 1].get()
        }
        throw ProcessRunner.RunnerError.ownershipLost
    }
}

final class RecordingSignalSender: @unchecked Sendable, ProcessSignalSending {
    var calls: [(Int32, Int32)] = []
    let result: Bool

    init(result: Bool = false) { self.result = result }

    func sendSignal(_ signal: Int32, to pid: Int32) -> Bool {
        calls.append((signal, pid))
        return result
    }
}

final class ManualDeadlineScheduler: @unchecked Sendable, DeadlineScheduling {
    private(set) var actions: [(id: Int, action: () -> Void)] = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> CancellableWork {
        let id = nextID; nextID += 1
        actions.append((id, action))
        return ManualWork { [weak self] in
            self?.actions.removeAll(where: { $0.id == id })
        }
    }

    /// Fire the next pending action synchronously. The caller must yield to allow
    /// any Task { } created by the action to be scheduled on the actor.
    func fireNext() {
        guard !actions.isEmpty else { return }
        let a = actions.removeFirst()
        a.action()
    }

    /// Fire all pending actions.
    func fireAll() {
        while !actions.isEmpty { fireNext() }
    }
}

final class ManualWork: @unchecked Sendable, CancellableWork {
    let onCancel: @Sendable () -> Void
    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

// MARK: - Tests

struct ProcessRunnerOwnedTerminationTests {

    let runner = ProcessRunner()
    let sleepyURL = URL(fileURLWithPath: "/bin/sleep")
    let trueURL = URL(fileURLWithPath: "/usr/bin/true")
    let shURL = URL(fileURLWithPath: "/bin/sh")

    // MARK: - Classification

    @Test func timeoutClassifiedCorrectly() async throws {
        await #expect(throws: ProcessRunner.RunnerError.timeoutReached(0.5)) {
            try await runner.run(executable: sleepyURL, arguments: ["10"], timeout: 0.5)
        }
    }

    @Test func cancellationClassifiedCorrectly() async throws {
        let task = Task {
            try await runner.run(executable: sleepyURL, arguments: ["30"], timeout: 10)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: ProcessRunner.RunnerError.cancelled) {
            try await task.value
        }
    }

    @Test func normalExitNotRemapped() async throws {
        let result = try await runner.run(executable: trueURL)
        #expect(result.exitCode == 0)
    }

    @Test func timeoutsDoNotOverrideNormalExit() async throws {
        let result = try await runner.run(executable: trueURL, timeout: 5)
        #expect(result.exitCode == 0)
    }

    // MARK: - Quick-exit output

    @Test func quickExitStdout() async throws {
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf hello"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello")
    }

    @Test func quickExitStderr() async throws {
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf err >&2"])
        #expect(result.exitCode == 0)
        #expect(result.stderr == "err")
    }

    // MARK: - Latch ordering

    @Test func latchOpenThenEvent() async throws {
        let latch = TerminationLatch()
        #expect(latch.record(TermEvent(exitCode: 0, signaled: false)) == true)
        #expect(latch.record(TermEvent(exitCode: 1, signaled: true)) == false)
    }

    @Test func latchCleanupClaimedThenEvent() async throws {
        let latch = TerminationLatch()
        if case .claimed = latch.claimCleanupIfNoTermination() { /* ok */ } else { #expect(Bool(false)) }
        #expect(latch.record(TermEvent(exitCode: 0, signaled: false)) == true)
        #expect(latch.snapshot() != nil)
    }

    @Test func latchEventFirstThenClaim() async throws {
        let latch = TerminationLatch()
        #expect(latch.record(TermEvent(exitCode: 0, signaled: false)) == true)
        switch latch.claimCleanupIfNoTermination() {
        case .alreadyExited(let ev): #expect(ev.exitCode == 0)
        case .claimed: #expect(Bool(false))
        }
    }

    @Test func latchDoubleClaim() async throws {
        let latch = TerminationLatch()
        if case .claimed = latch.claimCleanupIfNoTermination() { /* ok */ } else { #expect(Bool(false)) }
        if case .claimed = latch.claimCleanupIfNoTermination() { /* ok */ } else { #expect(Bool(false)) }
    }

    // MARK: - Pre-wait failure (fake identity + signal sender)

    @Test func preWaitOwnershipFailure() async throws {
        let fakeID = FakeIdentityProvider()
        let fakeSig = RecordingSignalSender()
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: fakeSig, identityProvider: fakeID, latch: latch)

        let idA = ProcessIdentitySnapshot(pid: 999, canonicalExecutablePath: "/a", startTimeSeconds: 100, startTimeMicroseconds: 1)
        let idB = ProcessIdentitySnapshot(pid: 999, canonicalExecutablePath: "/b", startTimeSeconds: 200, startTimeMicroseconds: 2)
        fakeID.responses = [.success(idB)] // returns B, mismatch with A
        await ctrl.setIdentity(idA)

        await ctrl.requestCancellation(pid: 99999)
        #expect(fakeSig.calls.isEmpty) // identity mismatch, no signal
        await #expect(throws: ProcessRunner.RunnerError.ownershipLost) {
            try await ctrl.wait(until: nil)
        }
    }

    @Test func preWaitSigtermFailure() async throws {
        let fakeID = FakeIdentityProvider()
        let fakeSig = RecordingSignalSender()
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: fakeSig, identityProvider: fakeID, latch: latch)

        let idA = ProcessIdentitySnapshot(pid: 999, canonicalExecutablePath: "/a", startTimeSeconds: 100, startTimeMicroseconds: 1)
        fakeID.responses = [.success(idA)]
        await ctrl.setIdentity(idA)

        await ctrl.requestCancellation(pid: 99999)
        #expect(fakeSig.calls.count == 1) // SIGTERM attempted
        await #expect(throws: ProcessRunner.RunnerError.signalFailed(signal: SIGTERM)) {
            try await ctrl.wait(until: nil)
        }
    }

    // MARK: - Deterministic probe tests (manual deadline scheduler)

    @Test func staleTokenSameController() async throws {
        let scheduler = ManualDeadlineScheduler()
        let fakeID = FakeIdentityProvider()
        let fakeSig = RecordingSignalSender()
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: fakeSig, identityProvider: fakeID,
                                  latch: latch, deadlineScheduler: scheduler)

        // Probe A starts via manual scheduler
        async let probeA = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        // Scheduler has probe A's deadline action; give the Task {
        // try await ctrl.probeRecordedTermination(...) } time to register
        // on the actor.  No real-time sleep needed — the probe completes
        // via event below.
        await Task.yield()

        // Complete probe A via termination event
        #expect(latch.record(TermEvent(exitCode: 55, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 55, signaled: false))
        #expect(try await probeA?.exitCode == 55)

        // Fire stale deadline action — probeToken is nil, ignored
        scheduler.fireNext()
        await Task.yield()

        // Main wait gets the same exit
        let main = try await ctrl.wait(until: nil)
        #expect(main?.event.exitCode == 55)
    }

    @Test func multipleProbeRejectedAndCleanup() async throws {
        let scheduler = ManualDeadlineScheduler()
        let fakeID = FakeIdentityProvider()
        let fakeSig = RecordingSignalSender()
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: fakeSig, identityProvider: fakeID,
                                  latch: latch, deadlineScheduler: scheduler)

        // Probe A
        async let probeA = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        await Task.yield()

        // Probe B rejected
        await #expect(throws: ProcessRunner.RunnerError.multipleWaiters) {
            try await ctrl.probeRecordedTermination(until: .now + .seconds(10))
        }

        // Complete probe A via event
        #expect(latch.record(TermEvent(exitCode: 66, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 66, signaled: false))
        #expect(try await probeA?.exitCode == 66)

        // Stale deadline action from probe A — ignored
        scheduler.fireAll()
        await Task.yield()
    }

    @Test func probeDeadlineThenMainWait() async throws {
        let scheduler = ManualDeadlineScheduler()
        let fakeID = FakeIdentityProvider()
        let fakeSig = RecordingSignalSender()
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: fakeSig, identityProvider: fakeID,
                                  latch: latch, deadlineScheduler: scheduler)

        // Probe starts
        async let probe = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        await Task.yield()

        // Fire deadline manually
        scheduler.fireNext()
        // Allow the Task { await self._probeDeadlineReached(...) } to be
        // scheduled on the actor.
        await Task.yield()

        // Probe returns nil (deadline)
        let probeResult = try await probe
        #expect(probeResult == nil)

        // Main WaitOutcome is still waiting
        #expect(latch.record(TermEvent(exitCode: 77, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 77, signaled: false))
        let main = try await ctrl.wait(until: nil)
        #expect(main?.event.exitCode == 77)
    }

    @Test func probeEventThenMainWait() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        async let probeResult = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        await Task.yield()
        #expect(latch.record(TermEvent(exitCode: 42, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 42, signaled: false))
        #expect(try await probeResult?.exitCode == 42)
        let main = try await ctrl.wait(until: nil)
        #expect(main?.event.exitCode == 42)
    }

    @Test func multipleProbesRejected() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        async let p1 = try ctrl.probeRecordedTermination(until: .now + .seconds(1))
        await Task.yield()
        await #expect(throws: ProcessRunner.RunnerError.multipleWaiters) {
            try await ctrl.probeRecordedTermination(until: .now + .seconds(1))
        }
        // Cancel probe A to avoid ResourceCleanup
        // Complete it via event
        #expect(latch.record(TermEvent(exitCode: 0, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 0, signaled: false))
        #expect(try await p1?.exitCode == 0)
    }

    // MARK: - Deterministic second-window

    @Test func deterministicSecondWindow() async throws {
        let fakeID = FakeIdentityProvider()
        fakeID.responses = [
            .failure(ProcessRunner.RunnerError.ownershipLost),
            .failure(ProcessRunner.RunnerError.ownershipLost)
        ]
        let fakeSig = RecordingSignalSender()
        let runner = ProcessRunner(identityProvider: fakeID, signalSender: fakeSig)

        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf second-window"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "second-window")
        #expect(fakeID.callCount == 2)
        #expect(fakeSig.calls.isEmpty)
    }

    @Test func probeSecondWindowViaRunner() async throws {
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf second-window"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "second-window")
    }

    @Test func identityResolutionGraceConstant() {
        #expect(ProcessRunner.identityResolutionGrace == 0.1)
    }
}
