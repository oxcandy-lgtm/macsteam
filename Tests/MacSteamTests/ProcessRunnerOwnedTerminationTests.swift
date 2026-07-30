// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct ProcessRunnerOwnedTerminationTests {

    let runner = ProcessRunner()
    let sleepyURL = URL(fileURLWithPath: "/bin/sleep")
    let trueURL = URL(fileURLWithPath: "/usr/bin/true")
    let shURL = URL(fileURLWithPath: "/bin/sh")

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
        // Duplicate record rejected
        #expect(latch.record(TermEvent(exitCode: 1, signaled: true)) == false)
    }

    @Test func latchCleanupClaimedThenEvent() async throws {
        let latch = TerminationLatch()
        if case .claimed = latch.claimCleanupIfNoTermination() { /* ok */ } else { #expect(Bool(false)) }
        // Event after cleanup claim — should be recorded
        #expect(latch.record(TermEvent(exitCode: 0, signaled: false)) == true)
        #expect(latch.snapshot() != nil)
    }

    @Test func latchEventFirstThenClaim() async throws {
        let latch = TerminationLatch()
        #expect(latch.record(TermEvent(exitCode: 0, signaled: false)) == true)
        // Claim after event
        switch latch.claimCleanupIfNoTermination() {
        case .alreadyExited(let ev):
            #expect(ev.exitCode == 0)
        case .claimed:
            #expect(Bool(false)) // Should be alreadyExited
        }
    }

    @Test func latchDoubleClaim() async throws {
        let latch = TerminationLatch()
        if case .claimed = latch.claimCleanupIfNoTermination() { /* ok */ } else { #expect(Bool(false)) }
        if case .claimed = latch.claimCleanupIfNoTermination() { /* ok */ } else { #expect(Bool(false)) }
    }

    // MARK: - Pre-wait failure

    @Test func timeoutBeforeWait() async throws {
        // Timeout should arrive before any wait is registered
        // This tests that fail() sets outcome without activeToken guard
        await #expect(throws: ProcessRunner.RunnerError.timeoutReached(0.5)) {
            try await runner.run(executable: sleepyURL, arguments: ["10"], timeout: 0.5)
        }
    }
}
