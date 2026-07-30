// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

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

    // MARK: - Probe coexistence (via TermController directly)

    @Test func probeEventThenMainWait() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // Start probe
        let probeTask = Task { try await ctrl.probeRecordedTermination(until: .now + .seconds(10)) }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate termination
        #expect(latch.record(TermEvent(exitCode: 42, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 42, signaled: false))

        // Probe should get event
        let probeResult = try await probeTask.value
        #expect(probeResult?.exitCode == 42)

        // Main wait should also get same event
        let mainResult = try await ctrl.wait(until: nil)
        #expect(mainResult?.event.exitCode == 42)
    }

    @Test func probeDeadlineThenMainWait() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // Probe with very short deadline (won't reach real termination)
        let probeTask = Task { try await ctrl.probeRecordedTermination(until: .now + .seconds(0.01)) }
        let probeResult = try await probeTask.value
        #expect(probeResult == nil) // deadline

        // Main wait still works
        #expect(latch.record(TermEvent(exitCode: 99, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 99, signaled: false))
        let mainResult = try await ctrl.wait(until: nil)
        #expect(mainResult?.event.exitCode == 99)
    }

    @Test func staleProbeTokenIgnored() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // First probe completes via event
        let probe1 = Task { try await ctrl.probeRecordedTermination(until: .now + .seconds(10)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(latch.record(TermEvent(exitCode: 1, signaled: false)) == true)
        await ctrl.handleRecorded(TermEvent(exitCode: 1, signaled: false))
        #expect(try await probe1.value?.exitCode == 1)

        // Second probe — stale token from probe1 should not affect
        let latch2 = TerminationLatch()
        let ctrl2 = TermController(signalSender: DarwinProcessSignalSender(),
                                   identityProvider: RealProcessIdentityProvider(), latch: latch2)
        let probe2 = Task { try await ctrl2.probeRecordedTermination(until: .now + .seconds(0.01)) }
        #expect(try await probe2.value == nil) // deadline, not stale override
    }

    @Test func multipleProbesRejected() async throws {
        let latch = TerminationLatch()
        let ctrl = TermController(signalSender: DarwinProcessSignalSender(),
                                  identityProvider: RealProcessIdentityProvider(), latch: latch)

        // First probe
        let p1 = Task { try? await ctrl.probeRecordedTermination(until: .now + .seconds(1)) }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Second probe should throw
        await #expect(throws: ProcessRunner.RunnerError.multipleWaiters) {
            try await ctrl.probeRecordedTermination(until: .now + .seconds(1))
        }
        p1.cancel()
    }

    // MARK: - Pre-wait failure

    @Test func timeoutBeforeWait() async throws {
        await #expect(throws: ProcessRunner.RunnerError.timeoutReached(0.5)) {
            try await runner.run(executable: sleepyURL, arguments: ["10"], timeout: 0.5)
        }
    }

    // MARK: - Identity resolution grace

    @Test func identityResolutionGraceConstant() {
        #expect(ProcessRunner.identityResolutionGrace == 0.1)
    }

    // MARK: - Deterministic second-window (via real process + identity lookup retry)

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
}
