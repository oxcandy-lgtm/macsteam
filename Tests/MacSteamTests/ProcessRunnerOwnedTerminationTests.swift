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

final class FakeSignalSender: @unchecked Sendable, ProcessSignalSending {
    var calls: [(Int32, Int32)] = []

    func sendSignal(_ signal: Int32, to pid: Int32) -> Bool {
        calls.append((signal, pid))
        return false
    }
}

final class ManualDeadlineScheduler: @unchecked Sendable, DeadlineScheduling {
    var pendingAction: (() -> Void)?

    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> CancellableWork {
        pendingAction = action
        return ManualCancellableWork { [weak self] in self?.pendingAction = nil }
    }

    func fireDeadline() {
        pendingAction?()
        pendingAction = nil
    }
}

final class ManualCancellableWork: @unchecked Sendable, CancellableWork {
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

    // MARK: - Deterministic pre-wait failure (fake identity + signal sender)

    @Test func preWaitOwnershipFailure() async throws {
        let fakeID = FakeIdentityProvider()
        let fakeSig = FakeSignalSender()
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: fakeSig, identityProvider: fakeID, latch: latch)

        let idA = ProcessIdentitySnapshot(pid: 999, canonicalExecutablePath: "/a", startTimeSeconds: 100, startTimeMicroseconds: 1)
        let idB = ProcessIdentitySnapshot(pid: 999, canonicalExecutablePath: "/b", startTimeSeconds: 200, startTimeMicroseconds: 2)
        fakeID.responses = [.success(idB)] // will return B
        await ctrl.setIdentity(idA)

        await ctrl.requestCancellation(pid: 99999) // synthetic PID, no real signal
        #expect(fakeSig.calls.isEmpty) // identity mismatch, no signal
        await #expect(throws: ProcessRunner.RunnerError.ownershipLost) {
            try await ctrl.wait(until: nil)
        }
    }

    @Test func preWaitSigtermFailure() async throws {
        let fakeID = FakeIdentityProvider()
        let fakeSig = FakeSignalSender()
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
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // Probe A completes via termination event
        async let probeA = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(latch.record(TermEvent(exitCode: 55, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 55, signaled: false))
        #expect(try await probeA?.exitCode == 55)

        // Main wait should get the same exit
        let main = try await ctrl.wait(until: nil)
        #expect(main?.event.exitCode == 55)
    }

    @Test func multipleProbeRejectedAndCleanup() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // Probe A
        async let probeA = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Probe B rejected
        await #expect(throws: ProcessRunner.RunnerError.multipleWaiters) {
            try await ctrl.probeRecordedTermination(until: .now + .seconds(10))
        }

        // Complete probe A via deadline (short deadline to avoid hang)
        #expect(latch.record(TermEvent(exitCode: 66, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 66, signaled: false))
        #expect(try await probeA?.exitCode == 66)
    }

    @Test func probeDeadlineThenMainWait() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // Probe with very short deadline (10ms)
        async let probe = try ctrl.probeRecordedTermination(until: .now + .seconds(0.01))
        let probeResult = try await probe
        #expect(probeResult == nil) // deadline reached

        // Main wait still works
        #expect(latch.record(TermEvent(exitCode: 77, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 77, signaled: false))
        let main = try await ctrl.wait(until: nil)
        #expect(main?.event.exitCode == 77)
    }

    // MARK: - Probe coexistence

    @Test func probeEventThenMainWait() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // Call probe from same context — it will be suspended by continuation
        // Then record termination to resume it
        async let probeResult = try ctrl.probeRecordedTermination(until: .now + .seconds(10))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(latch.record(TermEvent(exitCode: 42, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 42, signaled: false))
        #expect(try await probeResult?.exitCode == 42)
        let main = try await ctrl.wait(until: nil)
        #expect(main?.event.exitCode == 42)
    }

    // MARK: - Identity resolution grace

    @Test func identityResolutionGraceConstant() {
        #expect(ProcessRunner.identityResolutionGrace == 0.1)
    }

    @Test func secondWindowGrace() async throws {
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf second-window"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "second-window")
    }

    @Test func probeBeforeTermination() async throws {
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf hello"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello")
    }

    @Test func timeoutBeforeWait() async throws {
        await #expect(throws: ProcessRunner.RunnerError.timeoutReached(0.5)) {
            try await runner.run(executable: sleepyURL, arguments: ["10"], timeout: 0.5)
        }
    }
}
