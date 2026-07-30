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
            case .executableNotRegularFile(let url): return "Path is not a regular executable file: \(url.path)."
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

        // Detached mode: null device immediately, no pipes needed
        if case .detached = mode {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Discard policy: null device (wait mode), no pipes
        if case .discard = outputPolicy {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return ProcessResult(exitCode: process.terminationStatus, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Bounded capture
        let maxBytes: Int
        if case .boundedCapture(let bytes) = outputPolicy {
            maxBytes = bytes
        } else {
            maxBytes = 1024 * 1024
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends so EOF works
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // First-writer-wins termination intent
        let termIntent = TerminationIntent()

        // GCD-based pipe readers (readToEnd blocks GCD thread, not Swift concurrency)
        let stdoutResult = ThreadSafeData()
        let stderrResult = ThreadSafeData()

        DispatchQueue.global().async { [maxBytes] in
            let d = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            stdoutResult.value = d.prefix(maxBytes)
        }
        DispatchQueue.global().async { [maxBytes] in
            let d = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            stderrResult.value = d.prefix(maxBytes)
        }

        // Timeout work item
        var timeoutWork: DispatchWorkItem?
        if let timeoutSec = timeout {
            let work = DispatchWorkItem {
                if termIntent.request(.timeout(timeoutSec)) {
                    process.terminate()
                }
            }
            timeoutWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec, execute: work)
        }

        return try await withTaskCancellationHandler {
            // Wait for process exit on GCD
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }

            timeoutWork?.cancel()

            // Poll briefly for pipe readers to finish (process exit ensures EOF is coming)
            let pollStart = DispatchTime.now()
            while stdoutResult.value == nil || stderrResult.value == nil {
                if DispatchTime.now() > pollStart + .seconds(5) { break }
                try? await Task.sleep(for: .milliseconds(5))
            }

            let cause = termIntent.current

            if cause == .cancellation {
                throw RunnerError.cancelled
            }

            let outData = stdoutResult.value ?? Data()
            let errData = stderrResult.value ?? Data()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            if case .timeout = cause {
                throw RunnerError.timeoutReached(timeout ?? 0)
            }

            if process.terminationReason == .uncaughtSignal {
                throw RunnerError.processTerminated(signal: process.terminationStatus)
            }

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                pid: pid
            )
        } onCancel: {
            if termIntent.request(.cancellation) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

// MARK: - First-writer-wins termination intent

private final class TerminationIntent: @unchecked Sendable {
    private var _value: ProcessRunner.RequestedTermination = .none
    private let lock = NSLock()

    var current: ProcessRunner.RequestedTermination { lock.withLock { _value } }

    func request(_ new: ProcessRunner.RequestedTermination) -> Bool {
        lock.withLock {
            guard _value == .none else { return false }
            _value = new
            return true
        }
    }
}

// MARK: - Thread-safe data holder

private final class ThreadSafeData: @unchecked Sendable {
    private var _value: Data?
    private let lock = NSLock()

    var value: Data? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
