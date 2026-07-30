// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import MacsTeamNavigationCore
@testable import MacSteam

/// ProcessRunner output reliability tests (U1R16-R1F5).
struct ProcessRunnerOutputTests {
    let runner = ProcessRunner()

    @Test("stdout 0 bytes")
    func stdoutZeroBytes() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            timeout: 5
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "")
    }

    @Test("stdout 1 byte")
    func stdoutOneByte() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["-n", "a"],
            timeout: 5
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "a")
    }

    @Test("stdout hello world")
    func stdoutHelloWorld() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["Hello, World!"],
            timeout: 5
        )
        #expect(result.exitCode == 0)
        let trimmed = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        #expect(trimmed == "Hello, World!")
    }

    @Test("stdout 64 KiB")
    func stdout64KiB() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=64"],
            timeout: 10
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count >= 64000)
    }

    @Test("large stdout does not deadlock")
    func largeStdoutNoDeadlock() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=1024"],
            timeout: 15
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count <= 1024 * 1024 + 256)
    }

    @Test("100x stdout capture")
    func hundredTimesStdout() async throws {
        for _ in 0..<100 {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["Hello, World!"],
                timeout: 5
            )
            #expect(result.exitCode == 0)
            let trimmed = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            #expect(trimmed == "Hello, World!")
        }
    }
}

// MARK: - PrefixCleanupResult

@Test("cleanup result incomplete has reason")
func cleanupResultIncompleteHasReason() {
    let r = PrefixCleanupResult.incomplete(reason: "test error")
    if case .incomplete(let reason) = r {
        #expect(reason == "test error")
    } else {
        Issue.record("Expected incomplete")
    }
}

// MARK: - Navigation audit

@Test("navigation audit finds 6 pages")
func navigationAuditSixPages() async {
    let auditor = InstallerNavigationAuditor()
    let report = await auditor.audit()
    #expect(report.pageCount == 6)
}

@Test("navigation audit all back present")
func navigationAuditBackPresent() async {
    let auditor = InstallerNavigationAuditor()
    let report = await auditor.audit()
    #expect(report.backPresentAll == true)
}
