// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

final class FDLease: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    init(_ fd: Int32) { self.fd = fd }
    func borrow() throws -> Int32 {
        try lock.withLock { guard let f = fd else { throw ProcessRunner.RunnerError.pipeReadFailed }; return f }
    }
    func closeOnce() {
        let f: Int32? = lock.withLock { guard let d = fd else { return nil }; fd = nil; return d }
        if let d = f { Darwin.close(d) }
    }
    deinit { closeOnce() }
}

final class POSIXPipePair {
    let readFD: FDLease; let writeFD: FDLease
    init(readFD: Int32, writeFD: Int32) { self.readFD = FDLease(readFD); self.writeFD = FDLease(writeFD) }
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

final class ProcessOutputPipeBundle {
    let stdout: POSIXPipePair; let stderr: POSIXPipePair
    init() throws {
        self.stdout = try POSIXPipePair.createNonBlockingRead()
        do { self.stderr = try POSIXPipePair.createNonBlockingRead() }
        catch { stdout.closeAll(); throw ProcessRunner.RunnerError.pipeReadFailed }
    }
    func closeAll() { stdout.closeAll(); stderr.closeAll() }
}

/// Non-blocking bounded pipe capture. Atomic source registration (lock held through setup).
final class BoundedPipeCapture: @unchecked Sendable {
    enum State: Sendable {
        case idle; case starting; case reading; case completed(Data); case failed(ProcessRunner.RunnerError); case cancelled
    }

    private let readLease: FDLease
    private let limit: Int
    private var state: State = .idle
    private var storage = Data()
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()
    private var waiterSet = false

    init(readLease: FDLease, limit: Int) throws { _ = try readLease.borrow(); self.readLease = readLease; self.limit = limit }

    func start(on queue: DispatchQueue = .global()) throws {
        lock.lock()
        guard case .idle = state else { lock.unlock(); throw ProcessRunner.RunnerError.alreadyRunning }
        state = .starting

        let fd: Int32
        do { fd = try readLease.borrow() }
        catch {
            state = .failed(.pipeReadFailed)
            let w = continuation; continuation = nil
            lock.unlock()
            w?.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
            throw ProcessRunner.RunnerError.pipeReadFailed
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setCancelHandler { [readLease] in readLease.closeOnce() }
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate() }
            while true {
                let n = read(fd, buf, 65536)
                if n > 0 {
                    lock.lock(); if case .reading = state, storage.count < limit {
                        let cap = min(n, limit - storage.count); storage.append(buf, count: cap)
                    }; lock.unlock()
                    continue
                }
                if n == 0 { src.cancel(); complete(.success(storage)); return }
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                src.cancel(); complete(.failure(.pipeReadFailed)); return
            }
        }
        source = src
        state = .reading
        lock.unlock()
        src.resume()
    }

    func cancel() {
        lock.lock()
        switch state {
        case .idle, .starting, .reading: break
        default: lock.unlock(); return
        }
        state = .cancelled
        let c = continuation; continuation = nil
        let s = source; source = nil
        lock.unlock()
        if let src = s { src.cancel() } else { readLease.closeOnce() }
        c?.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
    }

    func waitForEOF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            switch state {
            case .idle, .starting, .reading:
                guard !waiterSet else { lock.unlock(); cont.resume(throwing: ProcessRunner.RunnerError.multipleWaiters); return }
                waiterSet = true; continuation = cont; lock.unlock()
            case .completed(let d): lock.unlock(); cont.resume(returning: d)
            case .failed(let err): lock.unlock(); cont.resume(throwing: err)
            case .cancelled: lock.unlock(); cont.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
            }
        }
    }

    /// Wait for EOF, but give up after `grace` seconds and return whatever has
    /// been captured so far.
    ///
    /// The launched process may legitimately exit while a daemonized descendant
    /// (e.g. Wine's `wineserver`) keeps the pipe write-ends open indefinitely.
    /// For an exited process the capture is best-effort: bounded output is
    /// drained within the grace window, then the read source is cancelled and
    /// the captured bytes returned.
    func waitForEOF(afterExitGrace grace: TimeInterval = 5.0) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            switch state {
            case .idle, .starting, .reading:
                guard !waiterSet else { lock.unlock(); cont.resume(throwing: ProcessRunner.RunnerError.multipleWaiters); return }
                waiterSet = true; continuation = cont; lock.unlock()
                let deadline = DispatchTime.now() + .milliseconds(Int(grace * 1000))
                DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
                    self?.completeGrace()
                }
            case .completed(let d): lock.unlock(); cont.resume(returning: d)
            case .failed(let err): lock.unlock(); cont.resume(throwing: err)
            case .cancelled: lock.unlock(); cont.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
            }
        }
    }

    /// Grace-drain completion: snapshot the captured bytes, cancel the read
    /// source (closing the read fd), and resume the waiter.
    private func completeGrace() {
        lock.lock()
        guard case .reading = state else { lock.unlock(); return }
        let data = storage
        state = .completed(data)
        let src = source; source = nil
        let c = continuation; continuation = nil
        lock.unlock()
        src?.cancel()
        c?.resume(returning: data)
    }

    private func resumeWaiter(throwing error: ProcessRunner.RunnerError) {
        let c: CheckedContinuation<Data, Error>? = lock.withLock { let c = continuation; continuation = nil; return c }
        c?.resume(throwing: error)
    }

    private func complete(_ r: Result<Data, ProcessRunner.RunnerError>) {
        lock.lock()
        guard case .reading = state else { lock.unlock(); return }
        switch r {
        case .success(let d): state = .completed(d)
        case .failure(let e): state = .failed(e)
        }
        let c = continuation; continuation = nil
        lock.unlock()
        switch r {
        case .success(let d): c?.resume(returning: d)
        case .failure(let e): c?.resume(throwing: e)
        }
    }
}
