// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin.sys.proc

// MARK: - Process identity

/// Snapshot of a running process identity for ownership verification.
struct ProcessIdentitySnapshot: Sendable, Equatable {
    let pid: Int32
    let executablePath: String
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

protocol ProcessIdentityProviding: Sendable {
    func identity(forPID pid: Int32) throws -> ProcessIdentitySnapshot
}

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
        case ownershipLost

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let url): return "Executable not found at \(url.path)."
            case .executableNotRegularFile(let url): return "Not a regular file: \(url.path)."
            case .processTerminated(let s): return "Terminated by signal \(s)."
            case .timeoutReached(let t): return "Timed out after \(t)s."
            case .cancelled: return "Process was cancelled."
            case .alreadyRunning: return "Already running."
            case .pipeReadFailed: return "Failed to read process output."
            case .ownershipLost: return "Process ownership verification failed."
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

    /// Dedicated serial queue for pipe readers (fixed thread pool, not global concurrent)
    private static let readerQueue = DispatchQueue(label: "com.nousresearch.macsteam.process-runner",
                                                     qos: .utility)

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

        // Configure output — discard uses null device only
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

        // Close parent write-ends so EOF works after child exits
        stdoutPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForWriting.closeFile()

        // Process identity
        let identity = OwnedProcessIdentity(
            pid: pid,
            executablePath: executable.path,
            startTimeSeconds: UInt64(Date().timeIntervalSince1970)
        )
        let termOwner = ProcessTerminationOwner(identity: identity)

        // Pipe readers on global queue (readToEnd blocks GCD thread, avoids Swift concurrency blocking)
        let stdoutResult = ThreadSafeData()
        let stderrResult = ThreadSafeData()
        if !isDiscard {
            if let soHandle = stdoutPipe?.fileHandleForReading {
                DispatchQueue.global().async { [maxBytes] in
                    let d = (try? soHandle.readToEnd()) ?? Data()
                    stdoutResult.value = d.prefix(maxBytes)
                    try? soHandle.close()
                }
            }
            if let seHandle = stderrPipe?.fileHandleForReading {
                DispatchQueue.global().async { [maxBytes] in
                    let d = (try? seHandle.readToEnd()) ?? Data()
                    stderrResult.value = d.prefix(maxBytes)
                    try? seHandle.close()
                }
            }
        } else {
            stdoutResult.value = Data()
            stderrResult.value = Data()
        }

        // Timeout (use global queue for timer)
        if let timeoutSec = timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec) { [pid] in
                guard termOwner.request(.timeout(timeoutSec)) else { return }
                guard termOwner.verifyOwnership(pid: pid) else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [pid] in
                    guard termOwner.verifyOwnership(pid: pid) else { return }
                    kill(pid, SIGKILL)
                }
            }
        }

        return try await withTaskCancellationHandler {
            // Wait for process exit via terminationHandler
            let processTerm: ProcessTermination = await withCheckedContinuation { (cont: CheckedContinuation<ProcessTermination, Never>) in
                process.terminationHandler = { proc in
                    cont.resume(returning: ProcessTermination(
                        status: proc.terminationStatus,
                        reason: proc.terminationReason
                    ))
                }
            }

            let cause = termOwner.current

            if cause == .cancellation {
                throw RunnerError.cancelled
            }

            // Wait for pipe readers (poll with timeout on dedicated queue result)
            if !isDiscard {
                let deadline = DispatchTime.now() + .seconds(10)
                while stdoutResult.value == nil || stderrResult.value == nil {
                    if DispatchTime.now() > deadline {
                        throw RunnerError.pipeReadFailed
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }

            let outData = stdoutResult.value ?? Data()
            let errData = stderrResult.value ?? Data()

            if case .timeout = cause {
                throw RunnerError.timeoutReached(timeout ?? 0)
            }

            if processTerm.reason == .uncaughtSignal {
                throw RunnerError.processTerminated(signal: processTerm.status)
            }

            return ProcessResult(
                exitCode: processTerm.status,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                pid: pid
            )
        } onCancel: {
            guard termOwner.request(.cancellation) else { return }
            guard termOwner.verifyOwnership(pid: pid) else { return }
            kill(pid, SIGTERM)
        }
    }
}

// MARK: - Process termination and identity

struct ProcessTermination: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
}

struct OwnedProcessIdentity: Sendable {
    let pid: Int32
    let executablePath: String
    let startTimeSeconds: UInt64
}

private final class ProcessTerminationOwner: @unchecked Sendable {
    private var _value: ProcessRunner.RequestedTermination = .none
    private let lock = NSLock()
    let identity: OwnedProcessIdentity

    var current: ProcessRunner.RequestedTermination { lock.withLock { _value } }
    init(identity: OwnedProcessIdentity) { self.identity = identity }

    func request(_ new: ProcessRunner.RequestedTermination) -> Bool {
        lock.withLock {
            guard _value == .none else { return false }
            _value = new
            return true
        }
    }

    func verifyOwnership(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        return true
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
