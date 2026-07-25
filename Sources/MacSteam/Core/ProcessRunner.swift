// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Safe process execution with no shell involvement.
///
/// All processes are launched via `Process.executableURL` + `Process.arguments`.
/// `/bin/sh -c`, `sudo`, and string concatenation of user input are strictly
/// forbidden.
actor ProcessRunner {

    // MARK: - Public types

    struct ProcessResult: Equatable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
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

    /// Maximum bytes to read from stdout/stderr per run.
    private let maxOutputBytes = 1024 * 1024  // 1 MB

    // MARK: - Run

    func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        mode: LaunchMode = .waitForExit
    ) async throws -> ProcessResult {
        // Verify executable
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

        // Safe minimal environment
        let safeEnv = environment ?? [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": ProcessInfo.processInfo.userName
        ]
        process.environment = safeEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Detached mode: return immediately after successful launch
        if case .detached = mode {
            // Drain pipes in background to prevent deadlock
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let _ = handle.availableData
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let _ = handle.availableData
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }

        // Wait-for-exit mode: use continuation with async pipe reading
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let collector = OutputCollector(maxBytes: self.maxOutputBytes)

                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                // Set up async readers
                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { return }
                    collector.appendStdout(data)
                }

                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { return }
                    collector.appendStderr(data)
                }

                // Timeout timer
                let timer: DispatchSourceTimer?
                if let timeoutSeconds = timeout {
                    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                    t.schedule(deadline: .now() + timeoutSeconds)
                    t.setEventHandler {
                        process.terminate()
                        collector.markTimedOut()
                    }
                    t.resume()
                    timer = t
                } else {
                    timer = nil
                }

                process.terminationHandler = { proc in
                    timer?.cancel()

                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil

                    // Read any remaining data
                    if let remainingOut = try? stdoutHandle.readToEnd() {
                        collector.appendStdout(remainingOut)
                    }
                    if let remainingErr = try? stderrHandle.readToEnd() {
                        collector.appendStderr(remainingErr)
                    }

                    let terminationStatus = proc.terminationStatus
                    let terminationReason = proc.terminationReason

                    if collector.didTimeOut {
                        continuation.resume(throwing: RunnerError.timeoutReached(timeout ?? 0))
                        return
                    }

                    if terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: RunnerError.processTerminated(signal: terminationStatus))
                        return
                    }

                    continuation.resume(returning: ProcessResult(
                        exitCode: terminationStatus,
                        stdout: collector.stdout,
                        stderr: collector.stderr
                    ))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Thread‑safe mutable accumulator for process output, used to avoid
/// Swift 6 Sendable closure capture issues with local `var`.
private final class OutputCollector: @unchecked Sendable {
    private var _stdout = Data()
    private var _stderr = Data()
    private var _timedOut = false
    private let maxBytes: Int
    private let lock = NSLock()

    var didTimeOut: Bool { lock.withLock { _timedOut } }
    var stdout: String { lock.withLock { String(data: _stdout, encoding: .utf8) ?? "" } }
    var stderr: String { lock.withLock { String(data: _stderr, encoding: .utf8) ?? "" } }

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func appendStdout(_ data: Data) {
        lock.lock()
        if _stdout.count < maxBytes {
            let cap = min(data.count, maxBytes - _stdout.count)
            _stdout.append(data.prefix(cap))
        }
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        if _stderr.count < maxBytes {
            let cap = min(data.count, maxBytes - _stderr.count)
            _stderr.append(data.prefix(cap))
        }
        lock.unlock()
    }

    func markTimedOut() {
        lock.withLock { _timedOut = true }
    }
}
