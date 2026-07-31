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
        // Deterministic: sleep 10 with a 2s timeout must produce
        // either timeoutReached or a termination-before-exit signal.
        do {
            let _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 2
            )
            Issue.record("Expected timeout or termination error")
        } catch let error as ProcessRunner.RunnerError {
            let acceptable: [ProcessRunner.RunnerError] = [
                .timeoutReached(2),
                .processTerminated(signal: 15)  // SIGTERM
            ]
            #expect(acceptable.contains(error),
                    "Got \(error), expected timeoutReached(2) or processTerminated(signal: 15)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancellationTerminatesChild() async {
        let sleeper = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                timeout: 30
            )
        }
        // Let the process start
        try? await Task.sleep(for: .milliseconds(200))
        sleeper.cancel()

        do {
            let _ = try await sleeper.value
            Issue.record("Expected cancellation error")
        } catch let error as ProcessRunner.RunnerError {
            #expect(error == .cancelled || error == .processTerminated(signal: 15))
        } catch is CancellationError {
            // Task cancellation propagated — also acceptable
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func detachedSpawnSuccess() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            mode: .detached
        )
        #expect(result.exitCode == 0)
    }

    @Test func detachedNonexistentThrows() async {
        let fakeURL = URL(fileURLWithPath: "/usr/bin/nonexistent_detached_xyz")
        await #expect(throws: ProcessRunner.RunnerError.self) {
            try await runner.run(executable: fakeURL, mode: .detached)
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

    @Test func largeStdoutDoesNotDeadlock() async throws {
        // dd with bs=1k count=1024 writes exactly 1 MB — right at the
        // output cap — to verify non-blocking pipe reading.
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=1024"],
            timeout: 10
        )
        // stdout should be truncated at 1 MB, not cause a deadlock
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count <= 1024 * 1024 + 256)  // small slack
    }

    @Test func largeStderrDoesNotDeadlock() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=1024", "status=progress"],
            timeout: 10
        )
        // stderr from dd's progress output should not deadlock
        #expect(result.exitCode == 0)
    }

    @Test func stdoutCapAtOneMB() async throws {
        // Generate 2 MB — the runner caps at 1 MB
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=2048"],
            timeout: 10
        )
        #expect(result.stdout.utf8.count <= 1024 * 1024 + 256)
    }

    @Test func exitCodePreserved() async throws {
        // Return non-zero exit code and verify it's preserved
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            timeout: 5
        )
        #expect(result.exitCode == 1)
    }
}
