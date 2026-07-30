// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// RAII ownership of a single file descriptor. Guarantees single close.
final class OwnedFD: @unchecked Sendable {
    private var fd: Int32?

    init(fd: Int32) {
        self.fd = fd
    }

    /// Take ownership, returning the fd. After this, close() becomes a no-op.
    func take() throws -> Int32 {
        guard let f = fd else { throw OwnedFDError.alreadyTaken }
        fd = nil
        return f
    }

    func close() {
        guard let f = fd else { return }
        fd = nil
        Darwin.close(f)
    }

    deinit { close() }
}

enum OwnedFDError: Error, Sendable {
    case alreadyTaken
}

/// Event-driven pipe capture using DispatchSourceRead per FD.
/// Non-blocking FDs, continuation-based waitForEOF, unified state transitions.
final class BoundedPipeCapture: @unchecked Sendable {
    enum State: Sendable {
        case idle
        case reading
        case completed(Data)
        case failed(ProcessRunner.RunnerError)
        case cancelled
    }

    private let ownedFD: OwnedFD
    private let limit: Int
    private var state: State = .idle
    private var storage = Data()
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    /// Create with an OwnedFD. Sets O_NONBLOCK on the fd.
    /// Throws if O_NONBLOCK cannot be set.
    init(fd rawFD: Int32, limit: Int) {
        // Set O_NONBLOCK so read() never blocks in the DispatchSource handler
        let flags = fcntl(rawFD, F_GETFL)
        if flags >= 0 { _ = fcntl(rawFD, F_SETFL, flags | O_NONBLOCK) }
        self.ownedFD = OwnedFD(fd: rawFD)
        self.limit = limit
    }

    /// Start event-driven reading on the provided queue.
    func start(on queue: DispatchQueue = .global()) {
        let rawFD: Int32
        do { rawFD = try ownedFD.take() }
        catch { return } // already taken or closed

        let src = DispatchSource.makeReadSource(fileDescriptor: rawFD, queue: queue)
        source = src

        lock.withLock { state = .reading }

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate() }

            while true {
                let n = read(rawFD, buf, 65536)
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
                // n < 0
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                // Real error
                src.cancel()
                complete(.failure(.pipeReadFailed))
                return
            }
        }

        src.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(rawFD)
        }

        src.resume()
    }

    /// Cancel reading. Closes FD via source cancel handler.
    func cancel() {
        lock.lock()
        // Already terminal or cancelled — no-op
        if case .completed = state { lock.unlock(); return }
        if case .failed = state { lock.unlock(); return }
        if case .cancelled = state { lock.unlock(); return }

        state = .cancelled
        let c = continuation
        continuation = nil
        let src = source
        source = nil
        lock.unlock()

        if let s = src {
            s.cancel()
        } else {
            ownedFD.close()
        }
        c?.resume(throwing: ProcessRunner.RunnerError.pipeReadFailed)
    }

    /// Wait for completion via continuation (no polling).
    func waitForEOF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            switch state {
            case .idle, .reading:
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

    /// Unified terminal state transition — resumes waiter exactly once.
    private func complete(_ result: Result<Data, ProcessRunner.RunnerError>) {
        let c: CheckedContinuation<Data, Error>?
        lock.lock()
        switch result {
        case .success(let d):
            state = .completed(d)
        case .failure(let err):
            state = .failed(err)
        }
        c = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let d):
            c?.resume(returning: d)
        case .failure(let err):
            c?.resume(throwing: err)
        }
    }
}
