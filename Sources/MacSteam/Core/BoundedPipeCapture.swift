// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Single FD with guaranteed exactly-one close.
final class FDLease: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?

    init(_ fd: Int32) { self.fd = fd }

    func value() -> Int32 {
        lock.withLock {
            guard let f = fd else { return -1 }
            fd = nil
            return f
        }
    }

    func closeOnce() {
        let f: Int32? = lock.withLock {
            guard let d = fd else { return nil }
            fd = nil
            return d
        }
        if let d = f { Darwin.close(d) }
    }

    deinit { closeOnce() }
}

/// RAII POSIX pipe pair. Read-end has O_NONBLOCK.
final class POSIXPipePair {
    let readFD: FDLease
    let writeFD: FDLease

    init(readFD: Int32, writeFD: Int32) {
        self.readFD = FDLease(readFD)
        self.writeFD = FDLease(writeFD)
    }

    static func createNonBlocking() throws -> POSIXPipePair {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunner.RunnerError.pipeReadFailed }
        let flags = fcntl(fds[0], F_GETFL)
        guard flags >= 0, fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fds[0]); Darwin.close(fds[1])
            throw ProcessRunner.RunnerError.pipeReadFailed
        }
        return POSIXPipePair(readFD: fds[0], writeFD: fds[1])
    }

    func closeAll() { readFD.closeOnce(); writeFD.closeOnce() }
}

/// Both stdout/stderr pipe pairs. Partial construction leaks 0.
final class ProcessOutputPipeBundle {
    let stdout: POSIXPipePair
    let stderr: POSIXPipePair

    init() throws {
        self.stdout = try POSIXPipePair.createNonBlocking()
        do { self.stderr = try POSIXPipePair.createNonBlocking() }
        catch { stdout.closeAll(); throw ProcessRunner.RunnerError.pipeReadFailed }
    }

    func closeAll() { stdout.closeAll(); stderr.closeAll() }
}

/// Non-blocking bounded pipe capture using DispatchSourceRead per FD.
final class BoundedPipeCapture: @unchecked Sendable {
    enum State: Sendable {
        case idle
        case reading
        case completed(Data)
        case failed(ProcessRunner.RunnerError)
        case cancelled
    }

    private let rawFD: Int32
    private let limit: Int
    private var state: State = .idle
    private var storage = Data()
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    /// Create with fd. Sets O_NONBLOCK (fail-closed — throws on failure).
    init(fd: Int32, limit: Int) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw ProcessRunner.RunnerError.pipeReadFailed
        }
        self.rawFD = fd
        self.limit = limit
    }

    /// Start event-driven reading.
    func start(on queue: DispatchQueue = .global()) {
        let src = DispatchSource.makeReadSource(fileDescriptor: rawFD, queue: queue)
        source = src
        let fd = rawFD // captured by value in cancel handler
        lock.withLock { state = .reading }

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate() }

            while true {
                let n = read(self.rawFD, buf, 65536)
                if n > 0 {
                    self.lock.lock()
                    if case .reading = self.state {
                        if self.storage.count < self.limit {
                            let cap = min(n, self.limit - self.storage.count)
                            self.storage.append(buf, count: cap)
                        }
                    }
                    self.lock.unlock()
                    continue
                }
                if n == 0 {
                    src.cancel()
                    self.complete(.success(self.storage))
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                src.cancel()
                self.complete(.failure(.pipeReadFailed))
                return
            }
        }

        // Cancel handler owns FD close directly (no weak self needed)
        src.setCancelHandler { Darwin.close(fd) }

        src.resume()
    }

    /// Cancel reading. Resumes waiter with pipeReadFailed.
    func cancel() {
        let c: CheckedContinuation<Data, Error>?
        lock.lock()
        let isTerminal: Bool
        switch state {
        case .idle, .reading: isTerminal = false
        default: isTerminal = true
        }
        guard !isTerminal else { lock.unlock(); return }
        state = .cancelled
        c = continuation
        continuation = nil
        let src = source
        source = nil
        lock.unlock()

        if let s = src { s.cancel() }
        else { Darwin.close(rawFD) } // Never started — close directly
        c?.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
    }

    /// Wait for completion via continuation (no polling).
    func waitForEOF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            switch state {
            case .idle, .reading:
                guard continuation == nil else {
                    lock.unlock()
                    cont.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
                    return
                }
                continuation = cont
                lock.unlock()
            case .completed(let d):
                lock.unlock()
                cont.resume(returning: d)
            case .failed(let err):
                lock.unlock()
                cont.resume(throwing: err)
            case .cancelled:
                lock.unlock()
                cont.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
            }
        }
    }

    private func complete(_ result: Result<Data, ProcessRunner.RunnerError>) {
        let c: CheckedContinuation<Data, Error>?
        lock.lock()
        // Terminal transition only once
        guard case .reading = state else { lock.unlock(); return }
        switch result {
        case .success(let d): state = .completed(d)
        case .failure(let err): state = .failed(err)
        }
        c = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let d): c?.resume(returning: d)
        case .failure(let err): c?.resume(throwing: err)
        }
    }
}
