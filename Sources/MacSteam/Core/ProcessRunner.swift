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

        // Output setup
        var isDiscard = false
        let maxBytes: Int
        switch outputPolicy {
        case .discard:
            isDiscard = true
            maxBytes = 0
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let b):
            maxBytes = b
        }

        let soPipe = Pipe()
        let sePipe = Pipe()
        process.standardOutput = soPipe
        process.standardError = sePipe

        try process.run()
        let pid = process.processIdentifier

        soPipe.fileHandleForWriting.closeFile()
        sePipe.fileHandleForWriting.closeFile()

        // GCD readers (proven reliable on this hardware)
        let soResult = ThreadSafeData()
        let seResult = ThreadSafeData()
        if !isDiscard {
            DispatchQueue.global().async { [maxBytes] in
                let d = (try? soPipe.fileHandleForReading.readToEnd()) ?? Data()
                soResult.value = d.prefix(maxBytes)
                try? soPipe.fileHandleForReading.close()
            }
            DispatchQueue.global().async { [maxBytes] in
                let d = (try? sePipe.fileHandleForReading.readToEnd()) ?? Data()
                seResult.value = d.prefix(maxBytes)
                try? sePipe.fileHandleForReading.close()
            }
        } else {
            soResult.value = Data()
            seResult.value = Data()
        }

        // Termination state
        let term = ProcessTermOwner()

        // Timeout
        if let t = timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + t) { [pid] in
                guard term.claim(.timeout(t)) else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [pid] in
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }

        return try await withTaskCancellationHandler {
            // Wait for process exit via GCD continuation
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }

            let cause = term.current

            if cause == .cancellation {
                throw RunnerError.cancelled
            }

            // Poll for GCD readers with timeout
            if !isDiscard {
                let deadline = DispatchTime.now() + .seconds(10)
                while soResult.value == nil || seResult.value == nil {
                    if DispatchTime.now() > deadline {
                        throw RunnerError.pipeReadFailed
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }

            let outData = soResult.value ?? Data()
            let errData = seResult.value ?? Data()

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
            guard term.claim(.cancellation) else { return }
            kill(pid, SIGTERM)
        }
    }
}

// MARK: - Termination state

private final class ProcessTermOwner: @unchecked Sendable {
    private var val: ProcessRunner.RequestedTermination = .none
    private let lk = NSLock()
    var current: ProcessRunner.RequestedTermination { lk.withLock { val } }
    func claim(_ v: ProcessRunner.RequestedTermination) -> Bool {
        lk.withLock {
            guard val == .none else { return false }
            val = v
            return true
        }
    }
}

// MARK: - Thread-safe data

private final class ThreadSafeData: @unchecked Sendable {
    private var v: Data?
    private let lk = NSLock()
    var value: Data? {
        get { lk.withLock { v } }
        set { lk.withLock { v = newValue } }
    }
}
