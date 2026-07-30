// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

/// Unit tests for BoundedStreamCollector with continuation-based waiting.
struct BoundedStreamCollectorTests {

    @Test("finish resumes waiter with data")
    func finishResumesWaiter() async throws {
        let col = BoundedStreamCollector(limit: 1024)
        col.append("hello".data(using: .utf8)!)
        let wait = Task { try await col.waitForCompletion() }
        col.finish()
        let data = try await wait.value
        #expect(String(data: data, encoding: .utf8) == "hello")
    }

    @Test("fail resumes waiter with error")
    func failResumesWaiter() async {
        let col = BoundedStreamCollector(limit: 1024)
        enum TestError: Error { case e }
        let wait = Task { try await col.waitForCompletion() }
        col.fail(TestError.e)
        await #expect(throws: TestError.self) {
            try await wait.value
        }
    }

    @Test("wait after finish returns immediately")
    func waitAfterFinish() async throws {
        let col = BoundedStreamCollector(limit: 1024)
        col.append(Data([0x41]))
        col.finish()
        let data = try await col.waitForCompletion()
        #expect(data.count == 1)
    }

    @Test("limit truncation")
    func limitTruncation() async throws {
        let col = BoundedStreamCollector(limit: 10)
        col.append(Data(repeating: 0x42, count: 100))
        col.finish()
        let data = try await col.waitForCompletion()
        #expect(data.count == 10)
    }

    @Test("append after limit is dropped")
    func appendAfterLimit() async throws {
        let col = BoundedStreamCollector(limit: 5)
        col.append(Data(repeating: 0x43, count: 5))
        col.append(Data(repeating: 0x44, count: 5))
        col.finish()
        let data = try await col.waitForCompletion()
        #expect(data.count == 5)
    }

    @Test("discard mode does not create collector")
    func discardNoCollector() async {
        let runner = ProcessRunner()
        let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 5,
            outputPolicy: .discard
        )
        #expect(result?.exitCode == 0)
        #expect(result?.stdout == "")
    }

    @Test("bounded capture max 64 KiB via dd")
    func boundedCapture64KiB() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1k", "count=64"],
            timeout: 15,
            outputPolicy: .boundedCapture(maxBytes: 1024)
        )
        #expect(result.stdout.utf8.count <= 1024 + 10)
    }
}
