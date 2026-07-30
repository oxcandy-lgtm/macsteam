// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Safe process execution with owned termination and bounded capture.
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
        case signalFailed(signal: Int32)

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
            case .signalFailed(let s): return "Failed to send signal \(s)."
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

    // MARK: - Dependencies

    private let identityProvider: any ProcessIdentityProviding
    private let signalSender: any ProcessSignalSending

    init(
        identityProvider: any ProcessIdentityProviding = RealProcessIdentityProvider(),
        signalSender: any ProcessSignalSending = DarwinProcessSignalSender()
    ) {
        self.identityProvider = identityProvider
        self.signalSender = signalSender
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

        // Configure output — discard never creates Pipes
        let isDiscard: Bool
        let maxBytes: Int
        let soPipe = Pipe()
        let sePipe = Pipe()

        switch outputPolicy {
        case .discard:
            isDiscard = true
            maxBytes = 0
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let bytes):
            isDiscard = false
            maxBytes = bytes
            process.standardOutput = soPipe
            process.standardError = sePipe
        }

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends so EOF works after child exits
        if !isDiscard {
            soPipe.fileHandleForWriting.closeFile()
            sePipe.fileHandleForWriting.closeFile()
        }

        // Capture real process identity (best-effort)
        let launchedIdentity: ProcessIdentitySnapshot
        if let id = try? identityProvider.identity(forPID: pid) {
            launchedIdentity = id
        } else {
            launchedIdentity = ProcessIdentitySnapshot(
                pid: pid,
                canonicalExecutablePath: executable.path,
                startTimeSeconds: 0,
                startTimeMicroseconds: 0
            )
        }

        // Owned process termination
        let termOwner = OwnedProcessTermination(
            launchedIdentity: launchedIdentity,
            signalSender: signalSender,
            identityProvider: identityProvider
        )

        // GCD pipe readers (proven reliable on this hardware)
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

        // Timeout escalation
        if let timeoutSec = timeout {
            termOwner.scheduleTimeout(after: timeoutSec, pid: pid)
        }

        return try await withTaskCancellationHandler {
            // Wait for process exit (GCD continuation — only pattern that works on this hw)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    cont.resume()
                }
            }

            let cause = termOwner.current

            if cause == .cancellation {
                throw RunnerError.cancelled
            }

            // Poll for GCD readers with 10s deadline
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
            _ = termOwner.request(.cancellation)
            termOwner.escalate(pid: pid)
        }
    }
}

// MARK: - OwnedProcessTermination

final class OwnedProcessTermination: @unchecked Sendable {
    let launchedIdentity: ProcessIdentitySnapshot
    private let signalSender: any ProcessSignalSending
    private let identityProvider: any ProcessIdentityProviding
    private var state: ProcessRunner.RequestedTermination = .none
    private let lock = NSLock()
    private var sigkillWork: DispatchWorkItem?

    var current: ProcessRunner.RequestedTermination { lock.withLock { state } }

    init(
        launchedIdentity: ProcessIdentitySnapshot,
        signalSender: any ProcessSignalSending,
        identityProvider: any ProcessIdentityProviding
    ) {
        self.launchedIdentity = launchedIdentity
        self.signalSender = signalSender
        self.identityProvider = identityProvider
    }

    func request(_ new: ProcessRunner.RequestedTermination) -> Bool {
        lock.withLock {
            guard state == .none else { return false }
            state = new
            return true
        }
    }

    func scheduleTimeout(after seconds: TimeInterval, pid: Int32) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            guard request(.timeout(seconds)) else { return }
            escalate(pid: pid)
        }
    }

    /// First-writer-wins escalation for timeout and cancellation.
    func escalate(pid: Int32) {
        guard verifyOwnership(pid: pid) else { return }
        _ = signalSender.sendSignal(SIGTERM, to: pid)

        let killWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard kill(pid, 0) == 0 else { return }
            guard verifyOwnership(pid: pid) else { return }
            _ = signalSender.sendSignal(SIGKILL, to: pid)
        }
        lock.withLock {
            sigkillWork?.cancel()
            sigkillWork = killWork
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killWork)
    }

    private func verifyOwnership(pid: Int32) -> Bool {
        guard launchedIdentity.startTimeSeconds > 0 else {
            return kill(pid, 0) == 0
        }
        guard let current = try? identityProvider.identity(forPID: pid) else {
            return false
        }
        return current == launchedIdentity
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
