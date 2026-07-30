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

    private let identityProvider: any ProcessIdentityProviding
    private let signalSender: any ProcessSignalSending

    init(
        identityProvider: any ProcessIdentityProviding = RealProcessIdentityProvider(),
        signalSender: any ProcessSignalSending = DarwinProcessSignalSender()
    ) {
        self.identityProvider = identityProvider
        self.signalSender = signalSender
    }

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

        // Configure output via ProcessOutputPipeBundle (RAII, FDLease-backed)
        var stdoutCapture: BoundedPipeCapture?
        var stderrCapture: BoundedPipeCapture?
        var outputBundle: ProcessOutputPipeBundle?

        switch outputPolicy {
        case .discard:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .boundedCapture(let maxBytes):
            let bundle = try ProcessOutputPipeBundle()
            outputBundle = bundle
            let soWrite = try bundle.stdout.writeFD.borrow()
            let seWrite = try bundle.stderr.writeFD.borrow()
            process.standardOutput = FileHandle(fileDescriptor: soWrite, closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: seWrite, closeOnDealloc: false)
            stdoutCapture = try BoundedPipeCapture(readLease: bundle.stdout.readFD, limit: maxBytes)
            stderrCapture = try BoundedPipeCapture(readLease: bundle.stderr.readFD, limit: maxBytes)
        }

        let captures = (stdoutCapture, stderrCapture)

        // Termination events (proven pattern)
        let events = TermEvents()

        process.terminationHandler = { [weak events] proc in
            events?.signal(exitCode: proc.terminationStatus, signalFlag: proc.terminationReason == .uncaughtSignal)
        }

        // Launch — keep original error
        do { try process.run() }
        catch {
            stdoutCapture?.cancel(); stderrCapture?.cancel()
            outputBundle?.closeAll()
            throw error
        }

        let pid = process.processIdentifier

        // Close parent write-ends (child inherited via fork)
        outputBundle?.stdout.writeFD.closeOnce()
        outputBundle?.stderr.writeFD.closeOnce()

        // Identity capture with quick-exit resolution
        let launchedIdentity: ProcessIdentitySnapshot?
        do {
            launchedIdentity = try identityProvider.identity(forPID: pid)
        } catch {
            // Identity lookup failed — check quick-exit
            guard process.isRunning else {
                // Process already exited — use termination event
                let term = await events.wait()
                events.cancelWork()
                if term.signaled { throw RunnerError.processTerminated(signal: term.exitCode) }
                captures.0?.start(); captures.1?.start()
                let outData = try await captures.0?.waitForEOF() ?? Data()
                let errData = try await captures.1?.waitForEOF() ?? Data()
                return ProcessResult(exitCode: term.exitCode, stdout: String(data: outData, encoding: .utf8) ?? "",
                                     stderr: String(data: errData, encoding: .utf8) ?? "", pid: pid)
            }
            // Process still running — try once more
            launchedIdentity = try? identityProvider.identity(forPID: pid)
            if launchedIdentity == nil {
                // Unresolved — terminate via Process API, no raw signal
                process.terminate()
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if !process.isRunning {
                        captures.0?.cancel(); captures.1?.cancel()
                        throw RunnerError.ownershipLost
                    }
                }
                captures.0?.cancel(); captures.1?.cancel()
                outputBundle?.closeAll()
                throw RunnerError.cleanupRequired
            }
        }

        // Start event-driven capture
        stdoutCapture?.start(); stderrCapture?.start()

        // Timeout
        if let t = timeout, let id = launchedIdentity {
            scheduleTimeout(after: t, pid: pid, identity: id, events: events)
        }

        return try await withTaskCancellationHandler {
            let term = await events.wait()
            events.cancelWork()

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

    private func scheduleTimeout(after seconds: TimeInterval, pid: Int32, identity: ProcessIdentitySnapshot, events: TermEvents) {
        let work = DispatchWorkItem { [weak self, weak events] in
            guard let self, let ev = events else { return }
            guard let cur = try? self.identityProvider.identity(forPID: pid), cur == identity else { return }
            ev.markTimedOut()
            guard self.signalSender.sendSignal(SIGTERM, to: pid) else {
                ev.markFailed(.signalFailed(signal: SIGTERM))
                return
            }
            let killWork = DispatchWorkItem { [weak self, weak events] in
                guard let self, let ev2 = events, ev2.wasTimedOut else { return }
                // Verify identity before SIGKILL
                do {
                    let cur2 = try self.identityProvider.identity(forPID: pid)
                    guard cur2 == identity else { return }
                } catch {
                    // Identity failure — propagate to waiter
                    ev2.markFailed(.ownershipLost)
                    return
                }
                guard self.signalSender.sendSignal(SIGKILL, to: pid) else {
                    ev2.markFailed(.signalFailed(signal: SIGKILL))
                    return
                }
            }
            ev.setKillWork(killWork)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killWork)
        }
        events.setTimeoutWork(work)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - TermEvents (proven pattern)

private final class TermEvents: @unchecked Sendable {
    private(set) var wasTimedOut = false
    private(set) var wasCancelled = false
    private var terminated = false
    private var exitCode: Int32 = 0
    private var signaled = false
    private var failed: ProcessRunner.RunnerError?
    private var cont: CheckedContinuation<TermEvent, Never>?
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?
    private let lock = NSLock()
    private var waiterSet = false

    func signal(exitCode code: Int32, signalFlag: Bool) {
        let c: CheckedContinuation<TermEvent, Never>?
        lock.lock()
        guard !terminated else { lock.unlock(); return }
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
            if let f = failed {
                lock.unlock()
                // Already failed — treat as normal exit (failure will be surfaced by caller)
                c.resume(returning: TermEvent(exitCode: -1, signaled: false))
                return
            }
            cont = c
            lock.unlock()
        }
    }

    func markTimedOut() { lock.withLock { wasTimedOut = true } }
    func markCancelled() { lock.withLock { wasCancelled = true } }
    func markFailed(_ err: ProcessRunner.RunnerError) { lock.withLock { failed = err } }
    func setTimeoutWork(_ w: DispatchWorkItem) { lock.withLock { timeoutWork = w } }
    func setKillWork(_ w: DispatchWorkItem) { lock.withLock { killWork = w } }

    func cancelWork() {
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
