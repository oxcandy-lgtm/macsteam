// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

actor ProcessRunner {

    struct ProcessResult: Equatable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let pid: Int32?
    }

    enum RunnerError: Error, LocalizedError, Equatable, Sendable {
        case executableNotFound(URL); case executableNotRegularFile(URL)
        case processTerminated(signal: Int32); case timeoutReached(TimeInterval)
        case cancelled; case alreadyRunning; case pipeReadFailed
        case ownershipLost; case signalFailed(signal: Int32)
        case multipleWaiters; case cleanupRequired

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let u): return "Executable not found at \(u.path)."
            case .executableNotRegularFile(let u): return "Not a regular file: \(u.path)."
            case .processTerminated(let s): return "Terminated by signal \(s)."
            case .timeoutReached(let t): return "Timed out after \(t)s."
            case .cancelled: return "Cancelled."
            case .alreadyRunning: return "Already running."
            case .pipeReadFailed: return "Failed to read process output."
            case .ownershipLost: return "Ownership verification failed."
            case .signalFailed(let s): return "Failed to send signal \(s)."
            case .multipleWaiters: return "Multiple waiters not supported."
            case .cleanupRequired: return "Child may still be running."
            }
        }
    }

    enum ProcessOutputPolicy: Sendable { case discard; case boundedCapture(maxBytes: Int) }

    private let identityProvider: any ProcessIdentityProviding
    private let signalSender: any ProcessSignalSending

    init(identityProvider: any ProcessIdentityProviding = RealProcessIdentityProvider(),
         signalSender: any ProcessSignalSending = DarwinProcessSignalSender()) {
        self.identityProvider = identityProvider; self.signalSender = signalSender
    }

    func run(executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
             workingDirectory: URL? = nil, timeout: TimeInterval? = nil, mode: LaunchMode = .waitForExit,
             outputPolicy: ProcessOutputPolicy = .boundedCapture(maxBytes: 1024 * 1024)) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw RunnerError.executableNotFound(executable) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDir), !isDir.boolValue else { throw RunnerError.executableNotRegularFile(executable) }

        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": ProcessInfo.processInfo.userName]
        if let wd = workingDirectory { process.currentDirectoryURL = wd }

        if case .detached = mode {
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "", pid: process.processIdentifier)
        }

        var stdoutCapture: BoundedPipeCapture?; var stderrCapture: BoundedPipeCapture?
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

        let termCtrl = TermController(signalSender: signalSender, identityProvider: identityProvider)

        process.terminationHandler = { [weak termCtrl] proc in
            termCtrl?.handleTermination(exitCode: proc.terminationStatus, signalled: proc.terminationReason == .uncaughtSignal)
        }

        do { try process.run() }
        catch { stdoutCapture?.cancel(); stderrCapture?.cancel(); outputBundle?.closeAll(); throw error }

        let pid = process.processIdentifier
        outputBundle?.stdout.writeFD.closeOnce(); outputBundle?.stderr.writeFD.closeOnce()

        // Identity resolution — returns .owned or .quickExit (never throws ownershipLost for quick exit)
        switch try await resolveIdentity(process: process, pid: pid, termCtrl: termCtrl,
                                          captures: (stdoutCapture, stderrCapture), outputBundle: outputBundle) {
        case .quickExit(let result):
            stdoutCapture?.cancel(); stderrCapture?.cancel()
            return result
        case .owned(let identity):
            await termCtrl.setIdentity(identity)
        }

        // Start captures with child cleanup on failure
        do {
            try stdoutCapture?.start(); try stderrCapture?.start()
        } catch {
            process.terminate()
            let outcome = try await cleanupChild(termCtrl: termCtrl, captures: (stdoutCapture, stderrCapture), outputBundle: outputBundle)
            switch outcome {
            case .exited: throw RunnerError.pipeReadFailed
            case .deadline: throw RunnerError.cleanupRequired
            }
        }

        if let t = timeout { await termCtrl.scheduleTimeout(after: t, pid: pid) }

        return try await withTaskCancellationHandler {
            guard let exit = try await termCtrl.wait(until: nil) else {
                stdoutCapture?.cancel(); stderrCapture?.cancel()
                throw RunnerError.cancelled
            }
            await termCtrl.cancelPending()

            if exit.cause == .cancellation {
                stdoutCapture?.cancel(); stderrCapture?.cancel()
                throw RunnerError.cancelled
            }

            let outData = try await stdoutCapture?.waitForEOF() ?? Data()
            let errData = try await stderrCapture?.waitForEOF() ?? Data()

            if case .timeout(let t) = exit.cause { throw RunnerError.timeoutReached(t) }
            if exit.event.signaled { throw RunnerError.processTerminated(signal: exit.event.exitCode) }

            return ProcessResult(exitCode: exit.event.exitCode, stdout: String(data: outData, encoding: .utf8) ?? "",
                                 stderr: String(data: errData, encoding: .utf8) ?? "", pid: pid)
        } onCancel: {
            Task { await termCtrl.requestCancellation(pid: pid) }
        }
    }

    // MARK: - Identity resolution

    enum IdentityResolution {
        case owned(ProcessIdentitySnapshot)
        case quickExit(ProcessResult)
    }

    private func resolveIdentity(process: Process, pid: Int32, termCtrl: TermController,
                                  captures: (BoundedPipeCapture?, BoundedPipeCapture?),
                                  outputBundle: ProcessOutputPipeBundle?) async throws -> IdentityResolution {
        do {
            let identity = try identityProvider.identity(forPID: pid)
            return .owned(identity)
        } catch {
            // Identity lookup failed — check quick exit
            guard process.isRunning else {
                // Quick exit — drain captures to EOF
                do {
                    try captures.0?.start(); try captures.1?.start()
                } catch {
                    captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
                    throw RunnerError.pipeReadFailed
                }

                let exit = try await termCtrl.wait(until: nil)
                guard let termExit = exit else {
                    captures.0?.cancel(); captures.1?.cancel()
                    throw RunnerError.ownershipLost
                }

                if termExit.event.signaled {
                    captures.0?.cancel(); captures.1?.cancel()
                    throw RunnerError.processTerminated(signal: termExit.event.exitCode)
                }

                let outData = try await captures.0?.waitForEOF() ?? Data()
                let errData = try await captures.1?.waitForEOF() ?? Data()

                return .quickExit(ProcessResult(exitCode: termExit.event.exitCode,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "", pid: pid))
            }

            // Process still running — try once more
            do {
                let identity = try identityProvider.identity(forPID: pid)
                return .owned(identity)
            } catch {
                // Unresolved — terminate via Process API
                process.terminate()
                let outcome = try await cleanupChild(termCtrl: termCtrl, captures: captures, outputBundle: outputBundle)
                switch outcome {
                case .exited: throw RunnerError.ownershipLost
                case .deadline: throw RunnerError.cleanupRequired
                }
            }
        }
    }

    // MARK: - Child cleanup

    enum ChildCleanupOutcome { case exited; case deadline }

    private func cleanupChild(termCtrl: TermController, captures: (BoundedPipeCapture?, BoundedPipeCapture?),
                               outputBundle: ProcessOutputPipeBundle?) async throws -> ChildCleanupOutcome {
        let cleanup: TermExit?
        do {
            cleanup = try await termCtrl.wait(until: .now + .seconds(2))
        } catch {
            captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
            throw error
        }
        captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
        return cleanup != nil ? .exited : .deadline
    }
}

// MARK: - TermController (single wait(until:) authority)

enum TermCause: Sendable, Equatable { case none; case timeout(TimeInterval); case cancellation }
struct TermEvent: Sendable { let exitCode: Int32; let signaled: Bool }
struct TermExit: Sendable { let event: TermEvent; let cause: TermCause }

private actor TermController {
    private let signalSender: any ProcessSignalSending
    private let identityProvider: any ProcessIdentityProviding
    private var launchedIdentity: ProcessIdentitySnapshot?
    private var result: Result<TermExit, ProcessRunner.RunnerError>?
    private var waiterCont: CheckedContinuation<Void, Never>?
    private var waiterSet = false
    private var deadlineWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var forceKillWork: DispatchWorkItem?
    private var cause: TermCause = .none

    init(signalSender: any ProcessSignalSending, identityProvider: any ProcessIdentityProviding) {
        self.signalSender = signalSender; self.identityProvider = identityProvider
    }

    func setIdentity(_ id: ProcessIdentitySnapshot) { launchedIdentity = id }

    nonisolated func handleTermination(exitCode: Int32, signalled: Bool) {
        Task { await self._handle(exitCode: exitCode, signalled: signalled) }
    }

    private func _handle(exitCode: Int32, signalled: Bool) {
        guard result == nil else { return }
        result = .success(TermExit(event: TermEvent(exitCode: exitCode, signaled: signalled), cause: cause))
        cancelAllWork()
        waiterCont?.resume(); waiterCont = nil
    }

    func wait(until deadline: ContinuousClock.Instant?) async throws -> TermExit? {
        if let r = result {
            switch r {
            case .success(let e): return e
            case .failure(let err): throw err
            }
        }
        guard !waiterSet else { throw ProcessRunner.RunnerError.multipleWaiters }
        waiterSet = true

        // Event-driven deadline via DispatchWorkItem
        if let d = deadline {
            let interval = d - ContinuousClock.now
            let nanos = UInt64(max(0, interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { await self._deadlineReached() }
            }
            deadlineWork = work
            if nanos > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanos)), execute: work)
            } else {
                work.perform()
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if result != nil { c.resume(); return }
            waiterCont = c
        }

        deadlineWork?.cancel(); deadlineWork = nil

        if let r = result {
            switch r {
            case .success(let e): return e
            case .failure(let err): throw err
            }
        }
        return nil
    }

    private func _deadlineReached() {
        guard waiterCont != nil else { return }
        deadlineWork = nil
        waiterCont?.resume(); waiterCont = nil
    }

    // MARK: - Failure

    private func fail(_ error: ProcessRunner.RunnerError) {
        guard result == nil else { return }
        result = .failure(error)
        cancelAllWork()
        waiterCont?.resume(); waiterCont = nil
    }

    private func cancelAllWork() {
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
        deadlineWork?.cancel(); deadlineWork = nil
    }

    // MARK: - Timeout / Cancellation

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

    private func claim(_ requested: TermCause) -> Bool {
        guard result == nil, cause == .none else { return false }
        cause = requested; return true
    }

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
        guard result == nil else { return }
        guard let identity = launchedIdentity else { fail(.ownershipLost); return }
        do {
            let current = try identityProvider.identity(forPID: pid)
            guard current == identity else { fail(.ownershipLost); return }
        } catch { fail(.ownershipLost); return }
        guard signalSender.sendSignal(SIGKILL, to: pid) else { fail(.signalFailed(signal: SIGKILL)); return }
    }

    func cancelPending() { timeoutWork?.cancel(); timeoutWork = nil; forceKillWork?.cancel(); forceKillWork = nil }
}
