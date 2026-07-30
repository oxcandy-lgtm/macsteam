// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct ProcessRunnerQuickExitTests {

    let runner = ProcessRunner()
    let trueURL = URL(fileURLWithPath: "/usr/bin/true")
    let echoURL = URL(fileURLWithPath: "/bin/echo")

    @Test func quickExitTrue() async throws {
        let result = try await runner.run(executable: trueURL)
        #expect(result.exitCode == 0)
        #expect(result.pid != nil)
    }

    @Test func quickExitEcho() async throws {
        let result = try await runner.run(executable: echoURL, arguments: ["hello"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hello"))
    }

    @Test func quickExitFalse() async throws {
        let falseURL = URL(fileURLWithPath: "/usr/bin/false")
        let result = try await runner.run(executable: falseURL)
        #expect(result.exitCode == 1)
    }

    @Test func sequentialEcho100() async throws {
        for _ in 0..<100 {
            let result = try await runner.run(executable: echoURL, arguments: ["test"])
            #expect(result.exitCode == 0)
        }
    }

    @Test func sequentialTrue100() async throws {
        for _ in 0..<100 {
            let result = try await runner.run(executable: trueURL)
            #expect(result.exitCode == 0)
        }
    }

    @Test func parallel20QuickExits() async throws {
        try await withThrowingTaskGroup(of: ProcessRunner.ProcessResult.self) { group in
            for _ in 0..<20 {
                group.addTask { try await self.runner.run(executable: self.trueURL) }
            }
            for try await result in group {
                #expect(result.exitCode == 0)
            }
        }
    }

    @Test func quickExitStdoutPreserved() async throws {
        let shURL = URL(fileURLWithPath: "/bin/sh")
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf out"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "out")
    }

    @Test func quickExitStderrPreserved() async throws {
        let shURL = URL(fileURLWithPath: "/bin/sh")
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf err >&2"])
        #expect(result.exitCode == 0)
        #expect(result.stderr == "err")
    }

    @Test func quickExitBothStreams() async throws {
        let shURL = URL(fileURLWithPath: "/bin/sh")
        let result = try await runner.run(executable: shURL, arguments: ["-c", "printf out; printf err >&2"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
    }
}
