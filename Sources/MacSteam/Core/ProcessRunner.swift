// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Safe process execution with no shell involvement.
actor ProcessRunner {

    struct ProcessResult: Equatable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let pid: Int32?
    }

    enum RunnerError: Error, LocalizedError, Equatable, Sendable {
        case executableNotFound(URL)
        case executableNotRegularFile(URL)
        case processTerminated(signal: Int32)
        case timeoutReached(TimeInterval)
        case cancelled
        case alreadyRunning
        case pipeReadFailed

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let url): return "Executable not found at \(url.path)."
            case .executableNotRegularFile(let url): return "Not a regular file: \(url.path)."
            case .processTerminated(let s): return "Terminated by signal \(s)."
            case .timeoutReached(let t): return "Timed out after \(t)s."
            case .cancelled: return "Process was cancelled."
            case .alreadyRunning: return "Already running."
            case .pipeReadFailed: return "Failed to read process output."
            }
        }
    }

    enum ProcessOutputPolicy: Sendable {
        case discard
        case boundedCapture(maxBytes: Int)
    }

    enum RequestedTermination: Sendable, Equatable {
        case none
        case timeout(TimeInterval)
        case cancellation
    }

    // MARK: - Run

    func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        mode: LaunchMode = .waitForExit,
        outputPolicy: ProcessOutputPolicy = .boundedCapture(maxBytes: 1024 * 1024)
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RunnerError.executableNotFound(executable)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDir), !isDir.boolValue else {
            throw RunnerError.executableNotRegularFile(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": ProcessInfo.processInfo.userName
        ]
        if let wd = workingDirectory { process.currentDirectoryURL = wd }

        // Detached mode
        if case .detached = mode {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Discard through common lifecycle
        let isDiscard: Bool
        let maxBytes: Int
        var stdoutCollector: BoundedStreamCollector?
        var stderrCollector: BoundedStreamCollector?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?

        switch outputPolicy {
        case .discard:
            isDiscard = true
            maxBytes = 0
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let bytes):
            isDiscard = false
            maxBytes = bytes
            let soPipe = Pipe()
            let sePipe = Pipe()
            stdoutPipe = soPipe
            stderrPipe = sePipe
            process.standardOutput = soPipe
            process.standardError = sePipe
            stdoutCollector = BoundedStreamCollector(limit: bytes)
            stderrCollector = BoundedStreamCollector(limit: bytes)
        }

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends so EOF works
        stdoutPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForWriting.closeFile()

        // First-writer-wins termination intent
        let termIntent = TerminationIntent()

        // Start GCD pipe readers
        if !isDiscard, let so = stdoutCollector, let se = stderrCollector,
           let soHandle = stdoutPipe?.fileHandleForReading,
           let seHandle = stderrPipe?.fileHandleForReading {
            DispatchQueue.global().async { readChunks(handle: soHandle, collector: so) }
            DispatchQueue.global().async { readChunks(handle: seHandle, collector: se) }
        }

        // Timeout escalation
        var timeoutWork: DispatchWorkItem?
        if let timeoutSec = timeout {
            let work = DispatchWorkItem { [process] in
                guard termIntent.request(.timeout(timeoutSec), process: process) else { return }
                process.terminate() // SIGTERM
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [pid] in
                    if process.isRunning {
                        kill(pid, SIGKILL)
                        process.waitUntilExit()
                    }
                }
            }
            timeoutWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec, execute: work)
        }

        return try await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }

            timeoutWork?.cancel()
            let cause = termIntent.current

            if cause == .cancellation {
                throw RunnerError.cancelled
            }

            let stdoutData = (try? await stdoutCollector?.waitForCompletion()) ?? Data()
            let stderrData = (try? await stderrCollector?.waitForCompletion()) ?? Data()

            if case .timeout = cause {
                throw RunnerError.timeoutReached(timeout ?? 0)
            }

            if process.terminationReason == .uncaughtSignal {
                throw RunnerError.processTerminated(signal: process.terminationStatus)
            }

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                pid: pid
            )
        } onCancel: {
            if termIntent.request(.cancellation, process: process) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

// MARK: - Pipe reader

private func readChunks(handle: FileHandle, collector: BoundedStreamCollector) {
    do {
        while true {
            guard let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty else { break }
            collector.append(chunk)
        }
        collector.finish()
    } catch {
        collector.fail(error)
    }
}

// MARK: - Bounded stream collector

final class BoundedStreamCollector: @unchecked Sendable {
    private var data: Data
    private let limit: Int
    private var isFinished = false
    private var failureError: Error?
    private var waiter: CheckedContinuation<Data, any Error>?
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = limit
        self.data = Data()
    }

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < limit {
            let cap = min(chunk.count, limit - data.count)
            data.append(chunk.prefix(cap))
        }
        lock.unlock()
    }

    func finish() {
        let w: CheckedContinuation<Data, any Error>?
        lock.lock()
        isFinished = true
        w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: data)
    }

    func fail(_ error: Error) {
        let w: CheckedContinuation<Data, any Error>?
        lock.lock()
        failureError = error
        isFinished = true
        w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: error)
    }

    func waitForCompletion() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            lock.lock()
            if let err = failureError {
                lock.unlock()
                cont.resume(throwing: err)
                return
            }
            if isFinished {
                let d = data
                lock.unlock()
                cont.resume(returning: d)
                return
            }
            waiter = cont
            lock.unlock()

            // Safety timeout: resume with current data after 10s
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let resumed: CheckedContinuation<Data, any Error>? = lock.withLock {
                    guard let w = waiter else { return nil }
                    waiter = nil
                    return w
                }
                resumed?.resume(returning: lock.withLock { data })
            }
        }
    }
}

// MARK: - First-writer-wins termination intent

private final class TerminationIntent: @unchecked Sendable {
    private var _value: ProcessRunner.RequestedTermination = .none
    private let lock = NSLock()

    var current: ProcessRunner.RequestedTermination { lock.withLock { _value } }

    func request(_ new: ProcessRunner.RequestedTermination, process: Process? = nil) -> Bool {
        lock.withLock {
            guard _value == .none else { return false }
            if let proc = process, !proc.isRunning { return false }
            _value = new
            return true
        }
    }
}
