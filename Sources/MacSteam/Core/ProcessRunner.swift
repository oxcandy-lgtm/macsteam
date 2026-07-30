// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

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

        // Configure output — discard creates no Pipes/POSIX pipes
        var stdoutCapture: BoundedPipeCapture?
        var stderrCapture: BoundedPipeCapture?
        var writeFds: (writeFd: Int32, errFd: Int32)? // for bounded mode cleanup

        switch outputPolicy {
        case .discard:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let maxBytes):
            var soFds: [Int32] = [0, 0]
            var seFds: [Int32] = [0, 0]
            guard pipe(&soFds) == 0, pipe(&seFds) == 0 else {
                throw RunnerError.pipeReadFailed
            }
            // Write-end: FileHandle for process stdout/stderr (no closeOnDealloc — we close manually)
            let soHandle = FileHandle(fileDescriptor: soFds[1], closeOnDealloc: false)
            let seHandle = FileHandle(fileDescriptor: seFds[1], closeOnDealloc: false)
            process.standardOutput = soHandle
            process.standardError = seHandle
            // Read-end: BoundedPipeCapture owns the fd
            stdoutCapture = BoundedPipeCapture(fd: soFds[0], limit: maxBytes)
            stderrCapture = BoundedPipeCapture(fd: seFds[0], limit: maxBytes)
            stdoutCapture!.start()
            stderrCapture!.start()
            writeFds = (soFds[1], seFds[1])
        }

        try process.run()
        let pid = process.processIdentifier

        // Close write-ends now — child inherited them via fork
        if let wfds = writeFds {
            close(wfds.writeFd)
            close(wfds.errFd)
        }

        // Capture real process identity (fail-closed — no fallback)
        let launchedIdentity: ProcessIdentitySnapshot
        do {
            launchedIdentity = try identityProvider.identity(forPID: pid)
        } catch {
            throw RunnerError.ownershipLost
        }

        // Owned process termination
        let termOwner = OwnedProcessTermination(
            launchedIdentity: launchedIdentity,
            signalSender: signalSender,
            identityProvider: identityProvider
        )

        // Timeout escalation
        if let timeoutSec = timeout {
            termOwner.scheduleTimeout(after: timeoutSec, pid: pid)
        }

        return try await withTaskCancellationHandler {
            // Wait for process exit (GCD continuation)
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

            // Read from BoundedPipeCapture (pipes at EOF after close+process exit)
            let outData = try await stdoutCapture?.waitForEOF() ?? Data()
            let errData = try await stderrCapture?.waitForEOF() ?? Data()

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
            try? termOwner.terminate(reason: .cancellation, pid: pid)
        }
    }

    private func verifyOwnership(pid: Int32, expected: ProcessIdentitySnapshot) throws {
        let current: ProcessIdentitySnapshot
        do { current = try identityProvider.identity(forPID: pid) }
        catch { throw RunnerError.ownershipLost }
        guard current == expected else { throw RunnerError.ownershipLost }
    }
}

// MARK: - OwnedProcessTermination

private final class OwnedProcessTermination: @unchecked Sendable {
    let launchedIdentity: ProcessIdentitySnapshot
    private let signalSender: any ProcessSignalSending
    private let identityProvider: any ProcessIdentityProviding
    private var state: ProcessRunner.RequestedTermination = .none
    private let lock = NSLock()
    private var sigkillWork: DispatchWorkItem?

    var current: ProcessRunner.RequestedTermination { lock.withLock { state } }

    init(launchedIdentity: ProcessIdentitySnapshot, signalSender: any ProcessSignalSending, identityProvider: any ProcessIdentityProviding) {
        self.launchedIdentity = launchedIdentity
        self.signalSender = signalSender
        self.identityProvider = identityProvider
    }

    func request(_ new: ProcessRunner.RequestedTermination) -> Bool {
        lock.withLock { guard state == .none else { return false }; state = new; return true }
    }

    func scheduleTimeout(after seconds: TimeInterval, pid: Int32) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            guard request(.timeout(seconds)) else { return }
            try? terminate(reason: .timeout(seconds), pid: pid)
        }
    }

    func terminate(reason: ProcessRunner.RequestedTermination, pid: Int32) throws {
        // Verify identity before SIGTERM
        let current: ProcessIdentitySnapshot
        do { current = try identityProvider.identity(forPID: pid) }
        catch { throw ProcessRunner.RunnerError.ownershipLost }
        guard current == launchedIdentity else { throw ProcessRunner.RunnerError.ownershipLost }

        // SIGTERM
        guard signalSender.sendSignal(SIGTERM, to: pid) else {
            throw ProcessRunner.RunnerError.signalFailed(signal: SIGTERM)
        }

        // Schedule SIGKILL escalation
        let killWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard kill(pid, 0) == 0 else { return }
            guard let ver = try? identityProvider.identity(forPID: pid), ver == launchedIdentity else { return }
            _ = signalSender.sendSignal(SIGKILL, to: pid)
        }
        lock.withLock { sigkillWork?.cancel(); sigkillWork = killWork }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killWork)
    }
}
