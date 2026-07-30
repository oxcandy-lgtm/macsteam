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

        // Discard: null device + common lifecycle
        let isDiscard: Bool
        let maxBytes: Int
        switch outputPolicy {
        case .discard:
            isDiscard = true
            maxBytes = 0
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let bytes):
            isDiscard = false
            maxBytes = bytes
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends so EOF works after child exits
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // GCD pipe readers (readToEnd blocks GCD thread, not Swift concurrency)
        let stdoutResult = ThreadSafeData()
        let stderrResult = ThreadSafeData()
        DispatchQueue.global().async { [maxBytes] in
            let d = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            stdoutResult.value = d.prefix(maxBytes)
            try? stdoutPipe.fileHandleForReading.close()
        }
        DispatchQueue.global().async { [maxBytes] in
            let d = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            stderrResult.value = d.prefix(maxBytes)
            try? stderrPipe.fileHandleForReading.close()
        }

        // First-writer-wins termination owner
        let termOwner = ProcessTerminationOwner(identity: OwnedProcessIdentity(
            pid: pid,
            executablePath: executable.path,
            processStartTime: UInt64(DispatchTime.now().uptimeNanoseconds)
        ))

        // Timeout escalation
        var timeoutWork: DispatchWorkItem?
        if let timeoutSec = timeout {
            let work = DispatchWorkItem { [pid] in
                guard termOwner.request(.timeout(timeoutSec)) else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
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
            let cause = termOwner.current

            if cause == .cancellation {
                throw RunnerError.cancelled
            }

            // Wait for GCD readers with timeout
            let deadline = DispatchTime.now() + .seconds(10)
            while stdoutResult.value == nil || stderrResult.value == nil {
                if DispatchTime.now() > deadline {
                    throw RunnerError.pipeReadFailed
                }
                try? await Task.sleep(for: .milliseconds(5))
            }

            let outData = stdoutResult.value ?? Data()
            let errData = stderrResult.value ?? Data()

            if case .timeout = cause {
                throw RunnerError.timeoutReached(timeout ?? 0)
            }

            if process.terminationReason == .uncaughtSignal {
                throw RunnerError.processTerminated(signal: process.terminationStatus)
            }

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                pid: pid
            )
        } onCancel: {
            guard termOwner.request(.cancellation) else { return }
            kill(pid, SIGTERM)
        }
    }
}

// MARK: - Process identity and termination owner

struct OwnedProcessIdentity: Sendable {
    let pid: Int32
    let executablePath: String
    let processStartTime: UInt64
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
            _value = new; return true
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
