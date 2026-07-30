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
        case multipleWaiters

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
            case .multipleWaiters: return "Multiple waiters not supported."
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
        var writeFds: (Int32, Int32)?

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
            stdoutCapture = try BoundedPipeCapture(fd: soFds[0], limit: maxBytes)
            stderrCapture = try BoundedPipeCapture(fd: seFds[0], limit: maxBytes)
            writeFds = (soFds[1], seFds[1])
        }

        let captures = (stdoutCapture, stderrCapture)

        // Termination controller (set before run)
        let termCtrl = TerminationController(
            signalSender: signalSender,
            identityProvider: identityProvider
        )

        process.terminationHandler = { [weak termCtrl] proc in
            termCtrl?.handleTermination(exitCode: proc.terminationStatus, signaled: proc.terminationReason == .uncaughtSignal)
        }

        do { try process.run() }
        catch {
            stdoutCapture?.cancel(); stderrCapture?.cancel()
            throw RunnerError.pipeReadFailed
        }

        let pid = process.processIdentifier
        if let w = writeFds { close(w.0); close(w.1) }

        // Identity capture with quick-exit resolution
        let launchedIdentity: ProcessIdentitySnapshot
        if let id = try? identityProvider.identity(forPID: pid) {
            launchedIdentity = id
            await termCtrl.setIdentity(launchedIdentity)
        } else {
            let snapshot = await termCtrl.snapshot()
            if let event = snapshot.event {
                // Process already exited — normal quick exit
                await termCtrl.setQuickExit(event)
                // Start captures (will get EOF immediately)
                stdoutCapture?.start()
                stderrCapture?.start()
                let outData = try await stdoutCapture?.waitForEOF() ?? Data()
                let errData = try await stderrCapture?.waitForEOF() ?? Data()
                return ProcessResult(
                    exitCode: event.exitCode,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    pid: pid
                )
            } else {
                // Process still running but identity inaccessible
                process.terminate()
                stdoutCapture?.cancel(); stderrCapture?.cancel()
                throw RunnerError.ownershipLost
            }
        }

        // Start event-driven capture
        stdoutCapture?.start(); stderrCapture?.start()

        // Timeout
        if let t = timeout {
            await termCtrl.scheduleTimeout(after: t, pid: pid)
        }

        return try await withTaskCancellationHandler {
            // Wait for process exit
            let snapshot = await termCtrl.waitForTermination()

            await termCtrl.cancelPending()

            if let failure = snapshot.failure {
                captures.0?.cancel(); captures.1?.cancel()
                throw failure
            }

            guard let event = snapshot.event else {
                captures.0?.cancel(); captures.1?.cancel()
                throw RunnerError.cancelled
            }

            if snapshot.cause == .cancellation {
                captures.0?.cancel(); captures.1?.cancel()
                throw RunnerError.cancelled
            }

            let outData = try await captures.0?.waitForEOF() ?? Data()
            let errData = try await captures.1?.waitForEOF() ?? Data()

            if case .timeout(let t) = snapshot.cause {
                throw RunnerError.timeoutReached(t)
            }

            if event.signaled {
                throw RunnerError.processTerminated(signal: event.exitCode)
            }

            return ProcessResult(
                exitCode: event.exitCode,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                pid: pid
            )
        } onCancel: {
            Task { await termCtrl.requestCancellation(pid: pid) }
        }
    }
}

// MARK: - Termination controller

enum TermCause: Sendable, Equatable {
    case none
    case timeout(TimeInterval)
    case cancellation
}

struct TermEvent: Sendable {
    let exitCode: Int32
    let signaled: Bool
}

struct TermSnapshot: Sendable {
    let event: TermEvent?
    let cause: TermCause
    let failure: ProcessRunner.RunnerError?
}

private actor TerminationController {
    private let signalSender: any ProcessSignalSending
    private let identityProvider: any ProcessIdentityProviding
    private var launchedIdentity: ProcessIdentitySnapshot?
    private var event: TermEvent?
    private var cause: TermCause = .none
    private var failure: ProcessRunner.RunnerError?
    private var terminationCont: CheckedContinuation<Void, Never>?
    private var timedOut = false
    private var cancelled = false
    private var quickExit = false
    private var timeoutWork: DispatchWorkItem?
    private var forceKillWork: DispatchWorkItem?

    init(signalSender: any ProcessSignalSending, identityProvider: any ProcessIdentityProviding) {
        self.signalSender = signalSender
        self.identityProvider = identityProvider
    }

    // MARK: - Identity

    func setIdentity(_ id: ProcessIdentitySnapshot) { launchedIdentity = id }
    func setQuickExit(_ ev: TermEvent) { quickExit = true; event = ev }

    // MARK: - Termination event (called from Process callback on GCD)

    nonisolated func handleTermination(exitCode: Int32, signaled: Bool) {
        Task { await self._handleTermination(exitCode: exitCode, signaled: signaled) }
    }

    private func _handleTermination(exitCode: Int32, signaled: Bool) {
        event = TermEvent(exitCode: exitCode, signaled: signaled)
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
        terminationCont?.resume()
        terminationCont = nil
    }

    // MARK: - Snapshot

    func snapshot() -> TermSnapshot {
        TermSnapshot(event: event, cause: cause, failure: failure)
    }

    // MARK: - Wait

    func waitForTermination() async -> TermSnapshot {
        if event != nil || failure != nil { return snapshot() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if event != nil || failure != nil { c.resume(); return }
            terminationCont = c
        }
        return snapshot()
    }

    // MARK: - Timeout

    func scheduleTimeout(after seconds: TimeInterval, pid: Int32) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self._handleTimeout(seconds: seconds, pid: pid) }
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func _handleTimeout(seconds: TimeInterval, pid: Int32) {
        // Claim timeout only if still running
        guard event == nil, !cancelled else { return }
        timedOut = true
        cause = .timeout(seconds)
        escalate(pid: pid)
    }

    // MARK: - Cancellation

    func requestCancellation(pid: Int32) {
        guard event == nil, !timedOut else { return }
        cancelled = true
        cause = .cancellation
        escalate(pid: pid)
    }

    // MARK: - Shared escalation

    private func escalate(pid: Int32) {
        guard let identity = launchedIdentity else {
            failure = .ownershipLost; resumeWaiter(); return
        }

        // Verify identity before SIGTERM
        do {
            let current = try identityProvider.identity(forPID: pid)
            guard current == identity else { failure = .ownershipLost; resumeWaiter(); return }
        } catch {
            failure = .ownershipLost; resumeWaiter(); return
        }

        // SIGTERM
        guard signalSender.sendSignal(SIGTERM, to: pid) else {
            failure = .signalFailed(signal: SIGTERM); resumeWaiter(); return
        }

        // SIGKILL after 2s
        let killWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self._escalateToKill(pid: pid) }
        }
        forceKillWork = killWork
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killWork)
    }

    private func _escalateToKill(pid: Int32) {
        guard event == nil else { return }
        guard let identity = launchedIdentity else { return }

        do {
            let current = try identityProvider.identity(forPID: pid)
            guard current == identity else { return }
        } catch { return }

        guard signalSender.sendSignal(SIGKILL, to: pid) else {
            failure = .signalFailed(signal: SIGKILL); resumeWaiter(); return
        }
    }

    private func resumeWaiter() {
        let c = terminationCont
        terminationCont = nil
        c?.resume()
    }

    func cancelPending() {
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
    }
}
