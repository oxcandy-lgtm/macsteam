// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

/// ProcessRunner extra verification tests (U1R16-R1F9 lifecycle core).
struct ProcessRunnerExtraTests {
    let runner = ProcessRunner()

    @Test("discard respects timeout")
    func discardRespectsTimeout() async {
        await #expect(throws: ProcessRunner.RunnerError.timeoutReached(1.0)) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                timeout: 1,
                outputPolicy: .discard
            )
        }
    }

    @Test("bounded capture at most 1 KiB")
    func boundedCaptureMaxSize() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=64"],
            timeout: 10,
            outputPolicy: .boundedCapture(maxBytes: 1024)
        )
        #expect(result.stdout.utf8.count <= 1024 + 10)
    }

    @Test("10 MiB stdout drain does not deadlock")
    func tenMiBDrain() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1m", "count=10"],
            timeout: 30,
            outputPolicy: .boundedCapture(maxBytes: 10 * 1024 * 1024)
        )
        #expect(result.exitCode == 0)
    }

    @Test("normal exit does not become timeout")
    func normalExitNotTimeout() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["ok"],
            timeout: 10,
            outputPolicy: .boundedCapture(maxBytes: 1024)
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == "ok")
    }

    @Test("20 concurrent runners")
    func concurrent20() async throws {
        try await withThrowingTaskGroup(of: ProcessRunner.ProcessResult.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await runner.run(
                        executable: URL(fileURLWithPath: "/bin/echo"),
                        arguments: ["hello"],
                        timeout: 10,
                        outputPolicy: .boundedCapture(maxBytes: 1024)
                    )
                }
            }
            var count = 0
            for try await result in group {
                #expect(result.exitCode == 0)
                count += 1
            }
            #expect(count == 20)
        }
    }

    @Test("detached 10 MiB output does not block")
    func detachedTenMiB() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1m", "count=10"],
            mode: .detached
        )
        #expect(result.exitCode == 0)
    }
}
