// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Event-driven pipe capture using DispatchSourceRead per FD.
/// No shared queues, no blocking reads, no polling.
final class BoundedPipeCapture: @unchecked Sendable {
    enum State: Sendable {
        case reading
        case completed(Data)
        case failed(ProcessRunner.RunnerError)
    }

    private let fd: Int32
    private let limit: Int
    private var state: State = .reading
    private var storage = Data()
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private let lock = NSLock()

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = limit
    }

    /// Start event-driven reading on the provided dispatch queue.
    func start(on queue: DispatchQueue = .global()) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = src

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buf.deallocate() }

            while true {
                let n = read(self.fd, buf, 65536)
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
                    // EOF
                    src.cancel()
                    finish(with: .completed(storage))
                    return
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { return } // wait for next event
                    // Real error
                    src.cancel()
                    finish(with: .failed(.pipeReadFailed))
                    return
                }
            }
        }

        src.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.fd)
        }

        src.resume()
    }

    /// Cancel reading and release the FD.
    func cancel() {
        lock.withLock {
            source?.cancel()
            source = nil
        }
        // Source's cancel handler closes the fd
    }

    /// Wait for EOF with continuation (no polling).
    func waitForEOF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            switch state {
            case .reading:
                continuation = cont
                lock.unlock()
            case .completed(let d):
                lock.unlock()
                cont.resume(returning: d)
            case .failed(let err):
                lock.unlock()
                cont.resume(throwing: err)
            }
        }
    }

    private func finish(with result: State) {
        let c: CheckedContinuation<Data, Error>?
        lock.lock()
        state = result
        c = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .completed(let d):
            c?.resume(returning: d)
        case .failed(let err):
            c?.resume(throwing: err)
        case .reading:
            break
        }
    }
}

// MARK: - Owned pipe endpoints

/// RAII ownership of a pipe pair. Ensures no double-close.
final class OwnedPipeEndpoints: @unchecked Sendable {
    private(set) var readFD: Int32
    private(set) var writeFD: Int32
    private var readClosed = false
    private var writeClosed = false
    private let lock = NSLock()

    init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
    }

    /// Transfer read FD ownership to a capture (marks as transferred).
    func transferReadOwnership() -> Int32 {
        lock.withLock {
            readClosed = true // ownership transferred, we won't close it
            return readFD
        }
    }

    func closeWriteEnd() {
        lock.withLock {
            guard !writeClosed else { return }
            writeClosed = true
            close(writeFD)
        }
    }

    func closeAll() {
        lock.withLock {
            if !readClosed { readClosed = true; close(readFD) }
            if !writeClosed { writeClosed = true; close(writeFD) }
        }
    }

    deinit {
        closeAll()
    }
}
