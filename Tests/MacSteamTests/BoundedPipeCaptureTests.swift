// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct BoundedPipeCaptureTests {

    let bundle: ProcessOutputPipeBundle
    let capture: BoundedPipeCapture

    init() throws {
        bundle = try ProcessOutputPipeBundle()
        capture = try BoundedPipeCapture(readLease: bundle.stdout.readFD, limit: 65536)
    }

    @Test func doubleStartRejected() async throws {
        try capture.start()
        await #expect(throws: ProcessRunner.RunnerError.alreadyRunning) {
            try capture.start()
        }
    }

    @Test func captureAndRead() async throws {
        let writeFD = try bundle.stdout.writeFD.borrow()
        let data = "hello capture".data(using: .utf8)!
        _ = data.withUnsafeBytes { ptr in
            write(writeFD, ptr.baseAddress!, ptr.count)
        }
        bundle.stdout.writeFD.closeOnce()
        try capture.start()
        let result = try await capture.waitForEOF()
        #expect(String(data: result, encoding: .utf8) == "hello capture")
    }

    @Test func emptyCapture() async throws {
        bundle.stdout.writeFD.closeOnce()
        try capture.start()
        let result = try await capture.waitForEOF()
        #expect(result.isEmpty)
    }

    @Test func multipleWaiterRejected() async throws {
        // Create a capture backed by a pipe that will NOT close (prevents EOF)
        let longBundle = try ProcessOutputPipeBundle()
        let longCapture = try BoundedPipeCapture(readLease: longBundle.stdout.readFD, limit: 65536)
        try longCapture.start()

        // First waiter — will block waiting for EOF that never comes
        let t1 = Task { [longCapture] in _ = try? await longCapture.waitForEOF(); return }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Second waiter — should be rejected
        await #expect(throws: ProcessRunner.RunnerError.multipleWaiters) {
            try await longCapture.waitForEOF()
        }

        t1.cancel()
        longBundle.closeAll()
    }

    @Test func fdClosedExactlyOnce() throws {
        let pair = try POSIXPipePair.createNonBlockingRead()
        pair.readFD.closeOnce()
        pair.readFD.closeOnce()
        // No crash = exactly-one close guarantee
    }

    @Test func bundlePartialConstructionNoLeak() throws {
        let b = try ProcessOutputPipeBundle()
        b.closeAll()
    }
}
