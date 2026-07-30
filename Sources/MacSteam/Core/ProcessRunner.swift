// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

actor ProcessRunner {

    struct ProcessResult: Equatable, Sendable {
        public let exitCode: Int32; public let stdout: String; public let stderr: String; public let pid: Int32?
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
            case .cancelled: return "Cancelled."; case .alreadyRunning: return "Already running."
            case .pipeReadFailed: return "Failed to read process output."
            case .ownershipLost: return "Ownership verification failed."
            case .signalFailed(let s): return "Failed to send signal \(s)."
            case .multipleWaiters: return "Multiple waiters not supported."
            case .cleanupRequired: return "Child may still be running."
            }
        }
    }

    enum ProcessOutputPolicy: Sendable { case discard; case boundedCapture(maxBytes: Int) }
    enum IdentityResolution { case owned(ProcessIdentitySnapshot); case quickExit(ProcessResult) }
    enum ChildCleanupOutcome { case exited; case deadline }

    private let identityProvider: any ProcessIdentityProviding
    private let signalSender: any ProcessSignalSending

    init(identityProvider: any ProcessIdentityProviding = RealProcessIdentityProvider(),
         signalSender: any ProcessSignalSending = DarwinProcessSignalSender()) {
        self.identityProvider = identityProvider; self.signalSender = signalSender
    }

    static let identityResolutionGrace = 0.1

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
        case .discard: process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        case .boundedCapture(let maxBytes):
            let bundle = try ProcessOutputPipeBundle()
            outputBundle = bundle
            process.standardOutput = FileHandle(fileDescriptor: try bundle.stdout.writeFD.borrow(), closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: try bundle.stderr.writeFD.borrow(), closeOnDealloc: false)
            stdoutCapture = try BoundedPipeCapture(readLease: bundle.stdout.readFD, limit: maxBytes)
            stderrCapture = try BoundedPipeCapture(readLease: bundle.stderr.readFD, limit: maxBytes)
        }

        let latch = TerminationLatch()
        let termCtrl = TermController(signalSender: signalSender, identityProvider: identityProvider, latch: latch)

        process.terminationHandler = { [weak termCtrl] proc in
            let event = TermEvent(exitCode: proc.terminationStatus, signaled: proc.terminationReason == .uncaughtSignal)
            guard latch.record(event) else { return }
            Task { await termCtrl?.handleRecorded(event) }
        }

        do { try process.run() }
        catch { stdoutCapture?.cancel(); stderrCapture?.cancel(); outputBundle?.closeAll(); throw error }

        let pid = process.processIdentifier
        outputBundle?.stdout.writeFD.closeOnce(); outputBundle?.stderr.writeFD.closeOnce()

        let captures = (stdoutCapture, stderrCapture)

        // Identity resolution with quick-exit helper
        switch try await resolveIdentity(process: process, pid: pid, latch: latch, termCtrl: termCtrl, captures: captures, outputBundle: outputBundle) {
        case .quickExit(let r): stdoutCapture?.cancel(); stderrCapture?.cancel(); return r
        case .owned(let id): await termCtrl.setIdentity(id)
        }

        do { try stdoutCapture?.start(); try stderrCapture?.start() }
        catch {
            process.terminate()
            let o = try await cleanupChild(termCtrl: termCtrl, captures: captures, outputBundle: outputBundle)
            switch o { case .exited: throw RunnerError.pipeReadFailed; case .deadline: throw RunnerError.cleanupRequired }
        }

        if let t = timeout { await termCtrl.scheduleTimeout(after: t, pid: pid) }

        return try await withTaskCancellationHandler {
            guard let exit = try await termCtrl.wait(until: nil) else {
                stdoutCapture?.cancel(); stderrCapture?.cancel(); throw RunnerError.cancelled
            }
            await termCtrl.cancelPending()
            if exit.cause == .cancellation { stdoutCapture?.cancel(); stderrCapture?.cancel(); throw RunnerError.cancelled }
            let outData = try await stdoutCapture?.waitForEOF() ?? Data()
            let errData = try await stderrCapture?.waitForEOF() ?? Data()
            if case .timeout(let t) = exit.cause { throw RunnerError.timeoutReached(t) }
            if exit.event.signaled { throw RunnerError.processTerminated(signal: exit.event.exitCode) }
            return ProcessResult(exitCode: exit.event.exitCode, stdout: String(data: outData, encoding: .utf8) ?? "",
                                 stderr: String(data: errData, encoding: .utf8) ?? "", pid: pid)
        } onCancel: { Task { await termCtrl.requestCancellation(pid: pid) } }
    }

    // MARK: - Quick-exit helper

    private func finishQuickExit(pid: Int32, termCtrl: TermController,
                                  captures: (BoundedPipeCapture?, BoundedPipeCapture?),
                                  outputBundle: ProcessOutputPipeBundle?) async throws -> IdentityResolution {
        // Start captures before waiting (must be active for waitForEOF)
        do { try captures.0?.start(); try captures.1?.start() }
        catch {
            captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
            throw RunnerError.pipeReadFailed
        }
        let exit = try await termCtrl.wait(until: nil)
        guard let t = exit else { captures.0?.cancel(); captures.1?.cancel(); throw RunnerError.ownershipLost }
        if t.event.signaled { captures.0?.cancel(); captures.1?.cancel(); throw RunnerError.processTerminated(signal: t.event.exitCode) }
        let o = try await captures.0?.waitForEOF() ?? Data()
        let e = try await captures.1?.waitForEOF() ?? Data()
        return .quickExit(ProcessResult(exitCode: t.event.exitCode, stdout: String(data: o, encoding: .utf8) ?? "",
                                        stderr: String(data: e, encoding: .utf8) ?? "", pid: pid))
    }

    // MARK: - Identity resolution with CleanupClaim

    private func resolveIdentity(process: Process, pid: Int32, latch: TerminationLatch, termCtrl: TermController,
                                  captures: (BoundedPipeCapture?, BoundedPipeCapture?),
                                  outputBundle: ProcessOutputPipeBundle?) async throws -> IdentityResolution {
        do { return .owned(try identityProvider.identity(forPID: pid)) }
        catch {
            // 1st identity failure — check quick exit
            if let latched = latch.snapshot() {
                return try await finishQuickExit(pid: pid, termCtrl: termCtrl, captures: captures,
                                                  outputBundle: outputBundle)
            }
            guard process.isRunning else {
                return try await finishQuickExit(pid: pid, termCtrl: termCtrl, captures: captures,
                                                  outputBundle: outputBundle)
            }
            // Process running — try once more
            do { return .owned(try identityProvider.identity(forPID: pid)) }
            catch {
                // 2nd identity failure — grace period before cleanup claim
                if let event = try await termCtrl.probeRecordedTermination(until: .now + .seconds(Self.identityResolutionGrace)) {
                    return try await finishQuickExit(pid: pid, termCtrl: termCtrl, captures: captures,
                                                      outputBundle: outputBundle)
                }
                // Probe deadline — use atomic cleanup claim
                switch latch.claimCleanupIfNoTermination() {
                case .alreadyExited:
                    return try await finishQuickExit(pid: pid, termCtrl: termCtrl, captures: captures,
                                                      outputBundle: outputBundle)
                case .claimed:
                    process.terminate()
                    let o = try await cleanupChild(termCtrl: termCtrl, captures: captures, outputBundle: outputBundle)
                    switch o { case .exited: throw RunnerError.ownershipLost; case .deadline: throw RunnerError.cleanupRequired }
                }
            }
        }
    }

    private func cleanupChild(termCtrl: TermController, captures: (BoundedPipeCapture?, BoundedPipeCapture?),
                               outputBundle: ProcessOutputPipeBundle?) async throws -> ChildCleanupOutcome {
        let c: TermExit?
        do { c = try await termCtrl.wait(until: .now + .seconds(2)) }
        catch { captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll(); throw error }
        captures.0?.cancel(); captures.1?.cancel(); outputBundle?.closeAll()
        return c != nil ? .exited : .deadline
    }
}

// MARK: - TerminationLatch

enum CleanupClaim: Sendable { case alreadyExited(TermEvent); case claimed }

enum LatchState: Sendable { case open; case cleanupClaimed; case terminated(TermEvent) }

final class TerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var state: LatchState = .open

    func record(_ e: TermEvent) -> Bool {
        lock.withLock {
            switch state {
            case .open, .cleanupClaimed:
                state = .terminated(e)
                return true
            case .terminated:
                return false
            }
        }
    }

    func snapshot() -> TermEvent? {
        lock.withLock {
            if case .terminated(let e) = state { return e }
            return nil
        }
    }

    func claimCleanupIfNoTermination() -> CleanupClaim {
        lock.withLock {
            switch state {
            case .terminated(let e): return .alreadyExited(e)
            case .open:
                state = .cleanupClaimed
                return .claimed
            case .cleanupClaimed:
                return .claimed
            }
        }
    }
}

// MARK: - Deadline scheduling

protocol CancellableWork: Sendable { func cancel() }

final class DispatchCancellableWork: @unchecked Sendable, CancellableWork {
    private let work: DispatchWorkItem
    init(_ w: DispatchWorkItem) { self.work = w }
    func cancel() { work.cancel() }
}

protocol DeadlineScheduling: Sendable {
    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> CancellableWork
}

final class DispatchDeadlineScheduler: DeadlineScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> CancellableWork {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        return DispatchCancellableWork(work)
    }
}

// MARK: - TermController

enum TermCause: Sendable, Equatable { case none; case timeout(TimeInterval); case cancellation }
struct TermEvent: Sendable { let exitCode: Int32; let signaled: Bool }
struct TermExit: Sendable { let event: TermEvent; let cause: TermCause }
enum WaitOutcome: Sendable { case waiting; case exited(TermExit); case failed(ProcessRunner.RunnerError); case deadline }

actor TermController {
    private let signalSender: any ProcessSignalSending
    private let identityProvider: any ProcessIdentityProviding
    private let latch: TerminationLatch
    private let deadlineScheduler: DeadlineScheduling
    private var launchedIdentity: ProcessIdentitySnapshot?
    private var outcome: WaitOutcome = .waiting
    private var waiterCont: CheckedContinuation<Void, Never>?
    private var waiterSet = false
    private var activeToken: UUID?
    private var deadlineWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var forceKillWork: DispatchWorkItem?
    private var cause: TermCause = .none
    private var probeContinuation: CheckedContinuation<TermEvent?, Error>?
    private var probeToken: UUID?

    init(signalSender: any ProcessSignalSending, identityProvider: any ProcessIdentityProviding,
         latch: TerminationLatch, deadlineScheduler: DeadlineScheduling = DispatchDeadlineScheduler()) {
        self.signalSender = signalSender; self.identityProvider = identityProvider; self.latch = latch
        self.deadlineScheduler = deadlineScheduler
    }

    func setIdentity(_ id: ProcessIdentitySnapshot) { launchedIdentity = id }

    func handleRecorded(_ event: TermEvent) {
        guard case .waiting = outcome else { return }
        outcome = .exited(TermExit(event: event, cause: cause))
        cancelAllWork()
        waiterCont?.resume(); waiterCont = nil
        probeContinuation?.resume(returning: event); probeContinuation = nil
        probeToken = nil
    }

    /// Non-consuming probe — does not affect waiterSet or main WaitOutcome.
    func probeRecordedTermination(until deadline: ContinuousClock.Instant) async throws -> TermEvent? {
        // Check immediate sources
        if let latched = latch.snapshot() { return latched }
        if case .exited(let e) = outcome { return e.event }

        guard probeContinuation == nil else { throw ProcessRunner.RunnerError.multipleWaiters }

        let token = UUID(); probeToken = token

        let interval = max(0, Double((deadline - ContinuousClock.now).components.seconds) +
            Double((deadline - ContinuousClock.now).components.attoseconds) / 1e18)
        let work = deadlineScheduler.schedule(after: interval) { [weak self] in
            guard let self else { return }
            Task { await self._probeDeadlineReached(token: token) }
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<TermEvent?, Error>) in
            if let latched = latch.snapshot() { c.resume(returning: latched); return }
            if case .exited(let e) = outcome { c.resume(returning: e.event); return }
            probeContinuation = c
        }
    }

    private func _probeDeadlineReached(token: UUID) {
        guard token == probeToken else { return }
        probeToken = nil
        probeContinuation?.resume(returning: nil); probeContinuation = nil
    }

    func wait(until deadline: ContinuousClock.Instant?) async throws -> TermExit? {
        if let latched = latch.snapshot(), case .waiting = outcome {
            outcome = .exited(TermExit(event: latched, cause: cause))
        }
        if case .exited(let e) = outcome { return e }
        if case .failed(let err) = outcome { throw err }
        guard !waiterSet else { throw ProcessRunner.RunnerError.multipleWaiters }
        waiterSet = true

        let token = UUID(); activeToken = token

        if let d = deadline {
            let interval = d - ContinuousClock.now
            let nanos = UInt64(max(0, interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { await self._deadlineReached(token: token) }
            }
            deadlineWork = work
            if nanos > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanos)), execute: work) }
            else { work.perform() }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if case .waiting = outcome { waiterCont = c; return }
            c.resume()
        }

        deadlineWork?.cancel(); deadlineWork = nil; activeToken = nil

        switch outcome {
        case .exited(let e): return e
        case .failed(let err): throw err
        case .deadline: return nil
        case .waiting: return nil
        }
    }

    private func _deadlineReached(token: UUID) {
        guard token == activeToken, case .waiting = outcome else { return }
        outcome = .deadline; deadlineWork = nil
        waiterCont?.resume(); waiterCont = nil
    }

    private func fail(_ error: ProcessRunner.RunnerError) {
        guard case .waiting = outcome else { return }
        // Check latch — synchronous termination beats cancel/timeout
        if let latched = latch.snapshot() {
            outcome = .exited(TermExit(event: latched, cause: cause))
        } else {
            outcome = .failed(error)
        }
        cancelAllWork()
        waiterCont?.resume(); waiterCont = nil
    }

    private func cancelAllWork() {
        timeoutWork?.cancel(); timeoutWork = nil
        forceKillWork?.cancel(); forceKillWork = nil
        deadlineWork?.cancel(); deadlineWork = nil
    }

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
        if let latched = latch.snapshot(), case .waiting = outcome {
            outcome = .exited(TermExit(event: latched, cause: cause))
            cancelAllWork(); waiterCont?.resume(); waiterCont = nil
            return false
        }
        guard case .waiting = outcome, cause == .none else { return false }
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
        guard case .waiting = outcome else { return }
        guard let identity = launchedIdentity else { fail(.ownershipLost); return }
        do {
            let current = try identityProvider.identity(forPID: pid)
            guard current == identity else { fail(.ownershipLost); return }
        } catch { fail(.ownershipLost); return }
        guard signalSender.sendSignal(SIGKILL, to: pid) else { fail(.signalFailed(signal: SIGKILL)); return }
    }

    func cancelPending() { timeoutWork?.cancel(); timeoutWork = nil; forceKillWork?.cancel(); forceKillWork = nil }
}
