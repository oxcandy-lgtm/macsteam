// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Bounded pipe capture using blocking reads on a dedicated queue.
/// The dedicated serial queue prevents GCD thread pool exhaustion.
final class BoundedPipeCapture: @unchecked Sendable {
    private let readFd: Int32
    private let limit: Int
    private var storage = Data()
    private var finished = false
    private let lock = NSLock()

    /// Create with a raw read fd (from Pipe.fileHandleForReading.fileDescriptor).
    init(fd: Int32, limit: Int) {
        self.readFd = fd
        self.limit = limit
    }

    /// Start blocking reads on the capture queue.
    func start() {
        Self.captureQueue.async { [weak self] in
            guard let self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate(); close(self.readFd) }

            while true {
                let n = read(self.readFd, buf, 65536)
                guard n > 0 else { break } // EOF (0) or error (<0)
                self.lock.lock()
                if self.storage.count < self.limit {
                    let cap = min(n, self.limit - self.storage.count)
                    self.storage.append(buf, count: cap)
                }
                self.lock.unlock()
            }

            self.lock.withLock { self.finished = true }
        }
    }

    /// Wait for EOF. Returns bounded data.
    func waitForEOF() async throws -> Data {
        let deadline = DispatchTime.now() + .seconds(10)
        while true {
            let (fin, dat) = lock.withLock { (finished, storage) }
            if fin { return dat }
            if DispatchTime.now() > deadline {
                throw ProcessRunner.RunnerError.pipeReadFailed
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static let captureQueue: DispatchQueue = {
        DispatchQueue(label: "com.nousresearch.macsteam.bounded-capture", qos: .utility)
    }()
}
