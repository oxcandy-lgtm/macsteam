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
        case cleanupRequired

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
            case .cleanupRequired: return "Child may still be running; cleanup required."
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
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        // Configure output via ProcessOutputPipeBundle
        var stdoutCapture: BoundedPipeCapture?
        var stderrCapture: BoundedPipeCapture?
        var outputBundle: ProcessOutputPipeBundle?

        switch outputPolicy {
        case .discard:
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        case .boundedCapture(let maxBytes):
            let bundle = try ProcessOutputPipeBundle()
            outputBundle = bundle
            process.standardOutput = FileHandle(fileDescriptor: try bundle.stdout.writeFD.borrow(), closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: try bundle.stderr.writeFD.borrow(), closeOnDealloc: false)
            stdoutCapture = try BoundedPipeCapture(readLease: bundle.stdout.readFD, limit: maxBytes)
            stderrCapture = try BoundedPipeCapture(readLease: bundle.stderr.readFD, limit: maxBytes)
        }

        let captures = (stdoutCapture, stderrCapture)

        // Termination events (single Result authority)
        let termCtrl = TermController(signalSender: signalSender, identityProvider: identityProvider)

        process.terminationHandler = { [weak termCtrl] proc in
            termCtrl?.handleTermination(exitCode: proc.terminationStatus, signalled: proc.terminationReason == .uncaughtSignal)
        }

        do { try process.run() }
        catch {
            stdoutCapture?.cancel(); stderrCapture?.cancel(); outputBundle?.closeAll()
            throw error
        }

        let pid = process.processIdentifier
        outputBundle?.stdout.writeFD.closeOnce(); outputBundle?.stderr.writeFD.closeOnce()

        // Identity capture with quick-exit resolution
        let launchedIdentity: ProcessIdentitySnapshot
        do {
            launchedIdentity = try await resolveIdentity(process: process, pid: pid, termCtrl: termCtrl, captures: captures, outputBundle: outputBundle)
        } catch let q as QuickResult {
            return q.result
        }
        await termCtrl.setIdentity(launchedIdentity)

        // Start captures (fail-closed)
        do {
            try stdoutCapture?.start(); try stderrCapture?.start()
        } catch {
            stdoutCapture?.cancel(); stderrCapture?.cancel()
            outputBundle?.closeAll()
            throw RunnerError.pipeReadFailed
        }

        // Timeout
        if let t = timeout {
            await termCtrl.scheduleTimeout(after: t, pid: pid)
        }

        return try await withTaskCancellationHandler {
            let result = try await termCtrl.wait()

            switch result {
            case .failed(let err):
                captures.0?.cancel(); captures.1?.cancel()
                throw err

            case .exited(let event, let cause):
                await termCtrl.cancelPending()

                if cause == .cancellation {
                    captures.0?.cancel(); captures.1?.cancel()
                    throw RunnerError.cancelled
                }

                let outData = try await captures.0?.waitForEOF() ?? Data()
                let errData = try await captures.1?.waitForEOF() ?? Data()

                if case .timeout(let t) = cause {
                    throw RunnerError.timeoutReached(t)
                }
                if event.signaled {
                    throw RunnerError.processTerminated(signal: event.exitCode)
                }
                return ProcessResult(exitCode: event.exitCode, stdout: String(data: outData, encoding: .utf8) ?? "",
                                     stderr: String(data: errData, encoding: .utf8) ?? "", pid: pid)

            case .running:
                captures.0?.cancel(); captures.1?.cancel()
                throw RunnerError.cancelled
            }
        } onCancel: {
            Task { await termCtrl.requestCancellation(pid: pid) }
        }
    }

    // MARK: - Identity resolution

    private func resolveIdentity(process: Process, pid: Int32, termCtrl: TermController,
                                  captures: (BoundedPipeCapture?, BoundedPipeCapture?),
                                  outputBundle: ProcessOutputPipeBundle?) async throws -> ProcessIdentitySnapshot {
        if let id = try? identityProvider.identity(forPID: pid) { return id }

        guard process.isRunning else {
            let result = await termCtrl.waitNoThrow()
            switch result {
            case .failed(let err): throw err
            case .exited(let event, _):
                if event.signaled { throw RunnerError.processTerminated(signal: event.exitCode) }
                try captures.0?.start(); try captures.1?.start()
                let outData = try await captures.0?.waitForEOF() ?? Data()
                let errData = try await captures.1?.waitForEOF() ?? Data()
                throw QuickResult(result: ProcessResult(exitCode: event.exitCode, stdout: String(data: outData, encoding: .utf8) ?? "",
                                                stderr: String(data: errData, encoding: .utf8) ?? "", pid: pid))
            case .running: throw RunnerError.ownershipLost
            }
        }

        // Process running but identity lookup failed — try once more
        if let id = try? identityProvider.identity(forPID: pid) { return id }

        // Unresolved — terminate via Process API
        process.terminate()
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !process.isRunning {
                captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
                throw RunnerError.ownershipLost
            }
        }
        captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
        throw RunnerError.cleanupRequired
    }}

// MARK: - QuickResult (escape hatch for quick-exit)

private struct QuickResult: Error { let result: ProcessRunner.ProcessResult }

// MARK: - TermController (single Result authority)

enum TerminationCause: Sendable, Equatable {
    case none
    case timeout(TimeInterval)
    case cancellation
}

enum TerminationResult: Sendable {
    case running
    case exited(TermEvent, cause: TerminationCause)
    case failed(ProcessRunner.RunnerError)
}

struct TermEvent: Sendable {
    let exitCode: Int32
    let signaled: Bool
}

private actor TermController {
    private let signalSender: any ProcessSignalSending
    private let identityProvider: any ProcessIdentityProviding
    private var launchedIdentity: ProcessIdentitySnapshot?
    private var result: TerminationResult = .running
    private var terminationCont: CheckedContinuation<Void, Never>?
    private var waiterSet = false
    private var timeoutWork: DispatchWorkItem?
    private var forceKillWork: DispatchWorkItem?
    private var cause: TerminationCause = .none

    init(signalSender: any ProcessSignalSending, identityProvider: any ProcessIdentityProviding) {
        self.signalSender = signalSender
        self.identityProvider = identityProvider
    }

    func setIdentity(_ id: ProcessIdentitySnapshot) { launchedIdentity = id }

    nonisolated func handleTermination(exitCode: Int32, signalled: Bool) {
        Task { await self._handle(exitCode: exitCode, signalled: signalled) }
    }

    private func _handle(exitCode: Int32, signalled: Bool) {
        guard case .running = result else { return }
        let ev = TermEvent(exitCode: exitCode, signaled: signalled)
        result = .exited(ev, cause: cause)
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
        let c = terminationCont; terminationCont = nil
        c?.resume()
    }

    // MARK: - Wait

    func wait() async throws -> TerminationResult {
        if case .failed = result { return result }
        if case .exited = result { return result }

        guard !waiterSet else { throw ProcessRunner.RunnerError.multipleWaiters }
        waiterSet = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            terminationCont = c
        }
        return result
    }

    // Non-throwing version for quick-exit path
    func waitNoThrow() async -> TerminationResult {
        if case .failed = result { return result }
        if case .exited = result { return result }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if case .running = result { terminationCont = c; return }
            c.resume()
        }
        return result
    }

    // MARK: - Failure

    private func fail(_ error: ProcessRunner.RunnerError) {
        guard case .running = result else { return }
        result = .failed(error)
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
        let c = terminationCont; terminationCont = nil
        c?.resume()
    }

    // MARK: - Timeout

    func scheduleTimeout(after seconds: TimeInterval, pid: Int32) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self._timeout(seconds: seconds, pid: pid) }
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func _timeout(seconds: TimeInterval, pid: Int32) {
        guard claim(.timeout(seconds)) else { return }
        escalate(pid: pid)
    }

    func requestCancellation(pid: Int32) {
        guard claim(.cancellation) else { return }
        escalate(pid: pid)
    }

    private func claim(_ requested: TerminationCause) -> Bool {
        guard case .running = result, cause == .none else { return false }
        cause = requested
        return true
    }

    // MARK: - Escalation (shared for timeout and cancellation)

    private func escalate(pid: Int32) {
        guard let identity = launchedIdentity else { fail(.ownershipLost); return }
        do {
            let current = try identityProvider.identity(forPID: pid)
            guard current == identity else { fail(.ownershipLost); return }
        } catch { fail(.ownershipLost); return }

        guard signalSender.sendSignal(SIGTERM, to: pid) else { fail(.signalFailed(signal: SIGTERM)); return }

        let killWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self._escalateToKill(pid: pid) }
        }
        forceKillWork = killWork
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killWork)
    }

    private func _escalateToKill(pid: Int32) {
        guard case .running = result else { return }
        guard let identity = launchedIdentity else { fail(.ownershipLost); return }
        do {
            let current = try identityProvider.identity(forPID: pid)
            guard current == identity else { fail(.ownershipLost); return }
        } catch { fail(.ownershipLost); return }
        guard signalSender.sendSignal(SIGKILL, to: pid) else { fail(.signalFailed(signal: SIGKILL)); return }
    }

    func cancelPending() {
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
    }
}
