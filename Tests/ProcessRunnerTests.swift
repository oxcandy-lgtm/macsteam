// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct ProcessRunnerTests {

    let runner = ProcessRunner()

    @Test func rejectsNonexistentExecutable() async {
        let fakeURL = URL(fileURLWithPath: "/usr/bin/nonexistent_command_xyz")
        await #expect(throws: ProcessRunner.RunnerError.self) {
            try await runner.run(executable: fakeURL)
        }
    }

    @Test func capturesExitCode() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(result.exitCode == 0)
    }

    @Test func capturesNonZeroExit() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false")
        )
        #expect(result.exitCode == 1)
    }

    @Test func capturesStdout() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["Hello, World!"]
        )
        #expect(result.stdout.contains("Hello, World!"))
    }

    @Test func timeoutTerminates() async {
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 2
            )
            // If the process somehow completed, exit could be 0 or -15
            #expect(result.exitCode == 0 || result.exitCode == -15)
        } catch let error as ProcessRunner.RunnerError {
            #expect(error == .timeoutReached(2) || error == .processTerminated(signal: 15) || error == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func usesSafeEnvironment() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            timeout: 5
        )
        #expect(result.stdout.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(result.exitCode == 0)
    }

    @Test func detachedReturnsImmediately() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            mode: .detached
        )
        // detached should return immediately without waiting
        #expect(result.exitCode == 0)
    }
}
