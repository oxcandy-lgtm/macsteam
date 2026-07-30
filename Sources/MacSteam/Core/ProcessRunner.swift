// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Safe process execution with no shell involvement.
actor ProcessRunner {

    // MARK: - Public types

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

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(url):
                return "Executable not found at \(url.path)."
            case let .executableNotRegularFile(url):
                return "Path is not a regular executable file: \(url.path)."
            case let .processTerminated(signal):
                return "Process terminated by signal \(signal)."
            case let .timeoutReached(seconds):
                return "Process timed out after \(seconds)s."
            case .cancelled:
                return "Process was cancelled."
            case .alreadyRunning:
                return "A process is already running."
            }
        }
    }

    /// Policy for capturing stdout/stderr.
    enum ProcessOutputPolicy: Sendable {
        case discard
        case boundedCapture(maxBytes: Int)
    }

    /// Reason the process stop was requested.
    enum RequestedTermination: Sendable {
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
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw RunnerError.executableNotRegularFile(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let safeEnv = environment ?? [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": ProcessInfo.processInfo.userName
        ]
        process.environment = safeEnv
        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }

        // Detached mode: null device, no pipes needed
        if case .detached = mode {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Wait-for-exit mode
        let maxBytes: Int
        if case .boundedCapture(let bytes) = outputPolicy {
            maxBytes = bytes
        } else {
            maxBytes = Int.max
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends after process launch so EOF works cleanly
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // Launch async reader tasks
        let stdoutTask = Task.detached { [maxBytes] in
            let data = try? stdoutPipe.fileHandleForReading.readToEnd()
            let capped = data?.prefix(maxBytes) ?? Data()
            return String(data: capped, encoding: .utf8) ?? ""
        }
        let stderrTask = Task.detached { [maxBytes] in
            let data = try? stderrPipe.fileHandleForReading.readToEnd()
            let capped = data?.prefix(maxBytes) ?? Data()
            return String(data: capped, encoding: .utf8) ?? ""
        }

        // Track cancellation
        let terminationIntent = MutableTerminationIntent()

        // Start timeout timer if specified
        if let timeoutSec = timeout {
            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSec))
                terminationIntent.set(.timeout(timeoutSec))
                if process.isRunning {
                    process.terminate()
                }
            }
        }

        return try await withTaskCancellationHandler {
            // Wait for exit on a dedicated queue (not blocking the swift concurrency thread pool)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }

            // Check for timeout (timer or cancellation)
            let cause = terminationIntent.current
            var stdout = ""
            var stderr = ""

            if case .cancellation = cause {
                stdoutTask.cancel()
                stderrTask.cancel()
                throw RunnerError.cancelled
            }

            stdout = await stdoutTask.value
            stderr = await stderrTask.value

            let terminationReason = process.terminationReason
            let terminationStatus = process.terminationStatus

            if case .timeout = cause {
                throw RunnerError.timeoutReached(timeout ?? 0)
            }

            if terminationReason == .uncaughtSignal {
                throw RunnerError.processTerminated(signal: terminationStatus)
            }

            return ProcessResult(
                exitCode: terminationStatus,
                stdout: stdout,
                stderr: stderr,
                pid: pid
            )
        } onCancel: {
            terminationIntent.set(.cancellation)
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Sendable holder for termination intent.
private final class MutableTerminationIntent: @unchecked Sendable {
    private var _value: ProcessRunner.RequestedTermination = .none
    private let lock = NSLock()

    var current: ProcessRunner.RequestedTermination { lock.withLock { _value } }

    func set(_ val: ProcessRunner.RequestedTermination) {
        lock.withLock { _value = val }
    }
}
