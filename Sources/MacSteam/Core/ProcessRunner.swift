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

        // Detached mode: null device immediately, no pipes
        if case .detached = mode {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Discard: null device, but still goes through common lifecycle
        let isDiscard: Bool
        let maxBytes: Int
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
        }

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends so EOF works (only for pipe mode)
        stdoutPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForWriting.closeFile()

        // First-writer-wins termination intent
        let termIntent = TerminationIntent()

        // GCD-based pipe readers (only for bounded capture)
        let stdoutResult = ThreadSafeData()
        let stderrResult = ThreadSafeData()

        if !isDiscard, let soHandle = stdoutPipe?.fileHandleForReading, let seHandle = stderrPipe?.fileHandleForReading {
            DispatchQueue.global().async { [maxBytes] in
                let d = (try? soHandle.readToEnd()) ?? Data()
                stdoutResult.value = d.prefix(maxBytes)
            }
            DispatchQueue.global().async { [maxBytes] in
                let d = (try? seHandle.readToEnd()) ?? Data()
                stderrResult.value = d.prefix(maxBytes)
            }
        } else {
            // Mark as done immediately for discard mode
            stdoutResult.value = Data()
            stderrResult.value = Data()
        }

        // Timeout work item
        var timeoutWork: DispatchWorkItem?
        if let timeoutSec = timeout {
            let work = DispatchWorkItem {
                if termIntent.request(.timeout(timeoutSec), process: process) {
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

            // Poll briefly for pipe readers to finish
            if !isDiscard {
                let pollStart = DispatchTime.now()
                while stdoutResult.value == nil || stderrResult.value == nil {
                    if DispatchTime.now() > pollStart + .seconds(5) { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
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
            if termIntent.request(.cancellation, process: process) {
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

    /// Attempt to set termination intent. Checks process is running.
    func request(_ new: ProcessRunner.RequestedTermination, process: Process? = nil) -> Bool {
        lock.withLock {
            guard _value == .none else { return false }
            if let proc = process, !proc.isRunning { return false }
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
