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

        if case .detached = mode {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Configure output
        var stdoutCapture: BoundedPipeCapture?
        var stderrCapture: BoundedPipeCapture?
        var writeFds: (Int32, Int32)? // write-end fds for bounded cleanup

        switch outputPolicy {
        case .discard:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let maxBytes):
            var soFds: [Int32] = [0, 0]; var seFds: [Int32] = [0, 0]
            guard pipe(&soFds) == 0 else { throw RunnerError.pipeReadFailed }
            guard pipe(&seFds) == 0 else { close(soFds[0]); close(soFds[1]); throw RunnerError.pipeReadFailed }
            process.standardOutput = FileHandle(fileDescriptor: soFds[1], closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: seFds[1], closeOnDealloc: false)
            stdoutCapture = BoundedPipeCapture(fd: soFds[0], limit: maxBytes)
            stderrCapture = BoundedPipeCapture(fd: seFds[0], limit: maxBytes)
            writeFds = (soFds[1], seFds[1])
        }

        // Termination handler (set before run)
        let events = ProcessTermEvents()

        process.terminationHandler = { [weak events] proc in
            events?.signal(exitCode: proc.terminationStatus, signalFlag: proc.terminationReason == .uncaughtSignal)
        }

        do { try process.run() }
        catch { stdoutCapture?.cancel(); stderrCapture?.cancel(); throw RunnerError.pipeReadFailed }

        let pid = process.processIdentifier

        // Close parent write-ends so EOF works after child exits
        if let w = writeFds { close(w.0); close(w.1) }

        // Identity capture (fail-closed)
        let launchedIdentity: ProcessIdentitySnapshot
        do { launchedIdentity = try identityProvider.identity(forPID: pid) }
        catch {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(200))
            stdoutCapture?.cancel(); stderrCapture?.cancel()
            throw RunnerError.ownershipLost
        }

        // Start event-driven capture
        stdoutCapture?.start(); stderrCapture?.start()

        // Timeout
        if let t = timeout {
            scheduleTimeout(after: t, pid: pid, identity: launchedIdentity, events: events)
        }

        let captures = (stdoutCapture, stderrCapture)

        return try await withTaskCancellationHandler {
            let term = await events.wait()

            events.cancelPending()

            let isTimeout = events.wasTimedOut
            let isCancelled = events.wasCancelled

            if isCancelled {
                captures.0?.cancel(); captures.1?.cancel()
                throw RunnerError.cancelled
            }

            let outData = try await captures.0?.waitForEOF() ?? Data()
            let errData = try await captures.1?.waitForEOF() ?? Data()

            if isTimeout { throw RunnerError.timeoutReached(timeout ?? 0) }
            if term.signaled { throw RunnerError.processTerminated(signal: term.exitCode) }

            return ProcessResult(
                exitCode: term.exitCode,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                pid: pid
            )
        } onCancel: {
            if (try? identityProvider.identity(forPID: pid)) != nil {
                _ = signalSender.sendSignal(SIGTERM, to: pid)
                events.markCancelled()
            }
        }
    }

    private func scheduleTimeout(after seconds: TimeInterval, pid: Int32, identity: ProcessIdentitySnapshot, events: ProcessTermEvents) {
        let work = DispatchWorkItem { [weak self, weak events] in
            guard let self, let ev = events else { return }
            guard let cur = try? self.identityProvider.identity(forPID: pid), cur == identity else { return }
            ev.markTimedOut()
            guard self.signalSender.sendSignal(SIGTERM, to: pid) else { return }
            let killWork = DispatchWorkItem { [weak self, weak events] in
                guard let self, let ev2 = events, ev2.wasTimedOut else { return }
                guard let cur2 = try? self.identityProvider.identity(forPID: pid), cur2 == identity else { return }
                _ = self.signalSender.sendSignal(SIGKILL, to: pid)
            }
            ev.setKillWork(killWork)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killWork)
        }
        events.setTimeoutWork(work)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - ProcessTermEvents

private final class ProcessTermEvents: @unchecked Sendable {
    private(set) var wasTimedOut = false
    private(set) var wasCancelled = false
    private var terminated = false
    private var exitCode: Int32 = 0
    private var signaled = false
    private var cont: CheckedContinuation<TermEvent, Never>?
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?
    private let lock = NSLock()

    func signal(exitCode code: Int32, signalFlag: Bool) {
        let c: CheckedContinuation<TermEvent, Never>?
        lock.lock()
        terminated = true; exitCode = code; signaled = signalFlag
        c = cont; cont = nil
        let tw = timeoutWork; timeoutWork = nil
        let kw = killWork; killWork = nil
        lock.unlock()
        tw?.cancel(); kw?.cancel()
        c?.resume(returning: TermEvent(exitCode: code, signaled: signalFlag))
    }

    func wait() async -> TermEvent {
        await withCheckedContinuation { (c: CheckedContinuation<TermEvent, Never>) in
            lock.lock()
            if terminated { lock.unlock(); c.resume(returning: TermEvent(exitCode: exitCode, signaled: signaled)); return }
            cont = c
            lock.unlock()
        }
    }

    func markTimedOut() { lock.withLock { wasTimedOut = true } }
    func markCancelled() { lock.withLock { wasCancelled = true } }
    func setTimeoutWork(_ w: DispatchWorkItem) { lock.withLock { timeoutWork = w } }
    func setKillWork(_ w: DispatchWorkItem) { lock.withLock { killWork = w } }

    func cancelPending() {
        lock.withLock {
            timeoutWork?.cancel(); timeoutWork = nil
            killWork?.cancel(); killWork = nil
        }
    }
}

struct TermEvent: Sendable {
    let exitCode: Int32
    let signaled: Bool
}
