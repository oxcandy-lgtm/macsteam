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

        // Configure output
        var stdoutCapture: BoundedPipeCapture?
        var stderrCapture: BoundedPipeCapture?
        var pipeEndpoints: (stdout: OwnedPipeEndpoints, stderr: OwnedPipeEndpoints)?

        switch outputPolicy {
        case .discard:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let maxBytes):
            var soFds: [Int32] = [0, 0]
            var seFds: [Int32] = [0, 0]
            guard pipe(&soFds) == 0 else { throw RunnerError.pipeReadFailed }
            guard pipe(&seFds) == 0 else {
                close(soFds[0]); close(soFds[1])
                throw RunnerError.pipeReadFailed
            }
            let soPipe = OwnedPipeEndpoints(readFD: soFds[0], writeFD: soFds[1])
            let sePipe = OwnedPipeEndpoints(readFD: seFds[0], writeFD: seFds[1])
            // Write-ends for Process
            process.standardOutput = FileHandle(fileDescriptor: soFds[1], closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: seFds[1], closeOnDealloc: false)
            // Captures own read FDs
            stdoutCapture = BoundedPipeCapture(fd: soPipe.transferReadOwnership(), limit: maxBytes)
            stderrCapture = BoundedPipeCapture(fd: sePipe.transferReadOwnership(), limit: maxBytes)
            pipeEndpoints = (soPipe, sePipe)
        }

        // Termination handler (set before run)
        let termEvents = ProcessTermEvents()

        process.terminationHandler = { [weak termEvents] proc in
            termEvents?.signal(exitCode: proc.terminationStatus, signalFlag: proc.terminationReason == .uncaughtSignal)
        }

        try process.run()
        let pid = process.processIdentifier

        // Close parent write-ends
        pipeEndpoints?.stdout.closeWriteEnd()
        pipeEndpoints?.stderr.closeWriteEnd()

        // Capture identity (fail-closed)
        let launchedIdentity: ProcessIdentitySnapshot
        do {
            launchedIdentity = try identityProvider.identity(forPID: pid)
        } catch {
            // Clean up child before throwing
            kill(pid, SIGTERM)
            stdoutCapture?.cancel()
            stderrCapture?.cancel()
            pipeEndpoints?.stdout.closeAll()
            pipeEndpoints?.stderr.closeAll()
            throw RunnerError.ownershipLost
        }

        // Start event-driven capture
        stdoutCapture?.start()
        stderrCapture?.start()

        // Timeout
        if let t = timeout {
            scheduleTimeout(after: t, pid: pid, identity: launchedIdentity, termEvents: termEvents)
        }

        let capturesForCancel = (stdoutCapture, stderrCapture)

        return try await withTaskCancellationHandler {
            // Wait for process exit
            let term = await termEvents.wait()

            // Cancel delayed work (timeout escalation)
            termEvents.cancelTimeout()

            let cause: RequestedTermination
            if term.signaled {
                if termEvents.timedOut { cause = .timeout(timeout ?? 0) }
                else { cause = .none }
            } else if termEvents.cancelled {
                cause = .cancellation
            } else {
                cause = .none
            }

            if cause == .cancellation {
                capturesForCancel.0?.cancel()
                capturesForCancel.1?.cancel()
                throw RunnerError.cancelled
            }

            let outData = try await stdoutCapture?.waitForEOF() ?? Data()
            let errData = try await stderrCapture?.waitForEOF() ?? Data()

            if case .timeout = cause {
                throw RunnerError.timeoutReached(timeout ?? 0)
            }

            if term.signaled {
                throw RunnerError.processTerminated(signal: term.exitCode)
            }

            return ProcessResult(
                exitCode: term.exitCode,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                pid: pid
            )
        } onCancel: {
            if kill(pid, 0) == 0 {
                kill(pid, SIGTERM)
                termEvents.markCancelled()
            }
        }
    }

    private func scheduleTimeout(after seconds: TimeInterval, pid: Int32, identity: ProcessIdentitySnapshot, termEvents: ProcessTermEvents) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak termEvents] in
            guard let ev = termEvents else { return }
            // Only act if process still running and not already cancelled
            guard kill(pid, 0) == 0 else { return }
            ev.markTimedOut()
            // Verify identity before signal
            guard let current = try? self.identityProvider.identity(forPID: pid), current == identity else { return }
            kill(pid, SIGTERM)
            // Force kill after 2s
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak termEvents] in
                guard let ev2 = termEvents, ev2.timedOut else { return }
                guard kill(pid, 0) == 0 else { return }
                guard let cur = try? self.identityProvider.identity(forPID: pid), cur == identity else { return }
                kill(pid, SIGKILL)
            }
        }
    }
}

// MARK: - Thread-safe termination events

private final class ProcessTermEvents: @unchecked Sendable {
    private var terminated = false
    private var exitCode: Int32 = 0
    private var signaled = false
    private(set) var timedOut = false
    private(set) var cancelled = false
    private var waiter: CheckedContinuation<TermEvent, Never>?
    private var timeoutWork: DispatchWorkItem?
    private let lock = NSLock()

    func signal(exitCode code: Int32, signalFlag: Bool) {
        let w: CheckedContinuation<TermEvent, Never>?
        lock.lock()
        terminated = true
        exitCode = code
        signaled = signalFlag
        w = waiter
        waiter = nil
        let tw = timeoutWork
        timeoutWork = nil
        lock.unlock()
        tw?.cancel()
        w?.resume(returning: TermEvent(exitCode: code, signaled: signalFlag))
    }

    func wait() async -> TermEvent {
        await withCheckedContinuation { (c: CheckedContinuation<TermEvent, Never>) in
            lock.lock()
            if terminated {
                lock.unlock()
                c.resume(returning: TermEvent(exitCode: exitCode, signaled: signaled))
                return
            }
            waiter = c
            lock.unlock()
        }
    }

    func markTimedOut() { lock.withLock { timedOut = true } }
    func markCancelled() { lock.withLock { cancelled = true } }
    func cancelTimeout() {
        lock.withLock {
            timeoutWork?.cancel()
            timeoutWork = nil
        }
    }
}

struct TermEvent: Sendable {
    let exitCode: Int32
    let signaled: Bool
}
