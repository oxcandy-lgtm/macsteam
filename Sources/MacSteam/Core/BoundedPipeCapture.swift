// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Single FD with guaranteed exactly-one close. Idempotent closeOnce().
final class FDLease: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?

    init(_ fd: Int32) { self.fd = fd }

    /// Read the fd without consuming ownership.
    func borrow() throws -> Int32 {
        try lock.withLock {
            guard let f = fd else { throw ProcessRunner.RunnerError.pipeReadFailed }
            return f
        }
    }

    /// Close exactly once. Second call is a no-op.
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

/// RAII POSIX pipe pair. All FDLease closeOnce() calls are idempotent.
final class POSIXPipePair {
    let readFD: FDLease
    let writeFD: FDLease

    init(readFD: Int32, writeFD: Int32) {
        self.readFD = FDLease(readFD)
        self.writeFD = FDLease(writeFD)
    }

    static func createNonBlockingRead() throws -> POSIXPipePair {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunner.RunnerError.pipeReadFailed }
        let flags = fcntl(fds[0], F_GETFL)
        guard flags >= 0, fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fds[0]); Darwin.close(fds[1])
            throw ProcessRunner.RunnerError.pipeReadFailed
        }
        return POSIXPipePair(readFD: fds[0], writeFD: fds[1])
    }

    func closeWriteEnd() { writeFD.closeOnce() }
    func closeAll() { readFD.closeOnce(); writeFD.closeOnce() }
}

/// Both stdout/stderr pipe pairs. Idempotent close — no double-close risk.
final class ProcessOutputPipeBundle {
    let stdout: POSIXPipePair
    let stderr: POSIXPipePair

    init() throws {
        self.stdout = try POSIXPipePair.createNonBlockingRead()
        do { self.stderr = try POSIXPipePair.createNonBlockingRead() }
        catch { stdout.closeAll(); throw ProcessRunner.RunnerError.pipeReadFailed }
    }

    func closeAll() { stdout.closeAll(); stderr.closeAll() }
}

/// Non-blocking bounded pipe capture using DispatchSourceRead per FD.
/// Owns the read FD via FDLease — cancel handler closes exactly once.
final class BoundedPipeCapture: @unchecked Sendable {
    enum State: Sendable {
        case idle
        case reading
        case completed(Data)
        case failed(ProcessRunner.RunnerError)
        case cancelled
    }

    private let readLease: FDLease
    private let limit: Int
    private var state: State = .idle
    private var storage = Data()
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()
    private var waiterSet = false

    /// Take an FDLease. May close it via cancel handler or deinit.
    init(readLease: FDLease, limit: Int) throws {
        _ = try readLease.borrow() // validate fd
        self.readLease = readLease
        self.limit = limit
    }

    /// Start event-driven reading.
    func start(on queue: DispatchQueue = .global()) {
        guard let fd = try? readLease.borrow() else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = src
        lock.withLock { state = .reading }

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate() }

            while true {
                let n = read(fd, buf, 65536)
                if n > 0 {
                    lock.lock()
                    if case .reading = state {
                        if storage.count < limit {
                            let cap = min(n, limit - storage.count)
                            storage.append(buf, count: cap)
                        }
                    }
                    lock.unlock()
                    continue
                }
                if n == 0 {
                    src.cancel()
                    complete(.success(storage))
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                src.cancel()
                complete(.failure(.pipeReadFailed))
                return
            }
        }

        src.setCancelHandler { [readLease] in readLease.closeOnce() }
        src.resume()
    }

    /// Cancel reading. Resumes waiter with pipeReadFailed.
    func cancel() {
        let c: CheckedContinuation<Data, Error>?
        lock.lock()
        let terminal: Bool
        switch state {
        case .idle, .reading: terminal = false
        default: terminal = true
        }
        guard !terminal else { lock.unlock(); return }
        state = .cancelled
        c = continuation
        continuation = nil
        let src = source
        source = nil
        lock.unlock()

        if let s = src { s.cancel() }
        else { readLease.closeOnce() }
        c?.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
    }

    func waitForEOF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            switch state {
            case .idle, .reading:
                guard !waiterSet else {
                    lock.unlock()
                    cont.resume(throwing: ProcessRunner.RunnerError.multipleWaiters)
                    return
                }
                waiterSet = true
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
