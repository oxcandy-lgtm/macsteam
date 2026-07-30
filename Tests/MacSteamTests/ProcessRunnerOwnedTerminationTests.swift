// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct ProcessRunnerOwnedTerminationTests {

    let runner = ProcessRunner()
    let sleepyURL = URL(fileURLWithPath: "/bin/sleep")
    let trueURL = URL(fileURLWithPath: "/usr/bin/true")

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

    @Test func quickExitStdout() async throws {
        let shURL = URL(fileURLWithPath: "/bin/sh")
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf hello"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello")
    }

    @Test func quickExitStderr() async throws {
        let shURL = URL(fileURLWithPath: "/bin/sh")
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf err >&2"])
        #expect(result.exitCode == 0)
        #expect(result.stderr == "err")
    }
}
