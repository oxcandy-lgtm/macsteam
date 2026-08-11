// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors from ProcessSupervisor operations.
enum ProcessSupervisorError: Error, Sendable, LocalizedError {
    case executableNotFound(URL)
    case launchFailed(String)
    case handleNotFound(UUID)
    case pidMismatch(owned: Int32, requested: Int32)
    case invalidPlan(String)
    case boundaryViolation(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url): return "Executable not found at \(url.path)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        case .handleNotFound(let token): return "No process for handle \(token)"
        case .pidMismatch(let owned, let requested):
            return "PID \(requested) not owned by this supervisor (owned: \(owned))"
        case .invalidPlan(let msg): return "Invalid launch plan: \(msg)"
        case .boundaryViolation(let msg): return "Execution boundary violation: \(msg)"
        }
    }
}

/// Safe base environment for Wine processes.
/// Values are never logged, only merged into the process environment.
enum SafeProcessEnvironment {
    static let base: [String: String] = [
        "HOME": NSHomeDirectory(),
        "USER": ProcessInfo.processInfo.userName,
        "LOGNAME": ProcessInfo.processInfo.userName,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": NSTemporaryDirectory(),
    ]

    /// Allowlisted environment keys for Wine processes.
    static let allowlistedKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG",
        "LC_ALL", "LC_MESSAGES", "LC_CTYPE",
        "WINEPREFIX", "WINEARCH", "WINEDEBUG", "WINEDLLOVERRIDES",
        "DYLD_LIBRARY_PATH", "FONTCONFIG_PATH",
        "DISPLAY", "WAYLAND_DISPLAY",
        "DXVK_HUD", "DXVK_STATE_CACHE",
        "STAGING_SHARED_MEMORY",
        "MTL_HUD_ENABLED",
    ]

    /// Merge user environment into the safe base, keeping only allowlisted keys.
    static func merged(with userEnv: [String: String]) -> [String: String] {
        var env = base
        for (key, value) in userEnv {
            guard allowlistedKeys.contains(key) else { continue }
            env[key] = value
        }
        return env
    }
}

/// Controls how child process stdout/stderr are handled.
enum ProcessOutputPolicy: Sendable {
    /// Discard all output (redirect to /dev/null).
    case discard
    /// Keep a bounded ring buffer for diagnostics.
    case boundedDiagnostics(maxBytes: Int)
}

/// Owns child `Process` objects on behalf of `GameSessionSupervisor`.
///
/// **U1R7:** The `Process` references live exclusively inside this actor.
/// No other type may hold a `Process` value.  Handles (`SupervisedProcessHandle`)
/// are passed outward instead.
actor ProcessSupervisor {

    private var processes: [UUID: Process] = [:]
    private var handleForPID: [Int32: UUID] = [:]
    private var outputBuffers: [UUID: Data] = [:]
    /// Root identity captured at launch time (production ownership ledger root).
    /// Never re-acquired at census time.
    private var rootIdentityByToken: [UUID: ProcessIdentity] = [:]

    // MARK: - Launch

    /// Launch a child process from the given plan.
    ///
    /// - Throws: `ProcessSupervisorError` on any failure.
    func launch(plan: LaunchPlan, outputPolicy: ProcessOutputPolicy = .discard) async throws -> SupervisedProcessHandle {
        // Validate plan
        guard plan.runtimeExecutable.isFileURL else {
            throw ProcessSupervisorError.invalidPlan("runtimeExecutable is not a file URL")
        }

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: plan.runtimeExecutable.path) else {
            throw ProcessSupervisorError.executableNotFound(plan.runtimeExecutable)
        }

        // Validate boundary if present
        if let boundary = plan.boundary {
            try boundary.validate(plan: plan)
        }

        // Build process
        let process = Process()
        process.executableURL = plan.runtimeExecutable
        process.arguments = plan.arguments

        // Merge environment: safe base + allowlisted plan values
        let safeEnv = SafeProcessEnvironment.merged(with: plan.environment)
        process.environment = safeEnv

        // Working directory
        if let wd = plan.workingDirectory {
            process.currentDirectoryURL = wd
        }

        // Default output: discard
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Bounded diagnostics uses pipes
        if case .boundedDiagnostics = outputPolicy {
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }

        // Launch
        try process.run()

        let token = UUID()
        let pid = process.processIdentifier
        guard pid > 0 else {
            throw ProcessSupervisorError.launchFailed("PID is 0 or negative")
        }

        // Configure output drainage (after launch, token is available)
        if case .boundedDiagnostics(let maxBytes) = outputPolicy {
            outputBuffers[token] = Data()
            if let outPipe = process.standardOutput as? Pipe {
                let readHandle = outPipe.fileHandleForReading
                readHandle.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    Task { await self.appendOutput(token: token, data: data, maxBytes: maxBytes) }
                }
            }
            if let errPipe = process.standardError as? Pipe {
                let errHandle = errPipe.fileHandleForReading
                errHandle.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let self else { return }
                    Task { await self.appendOutput(token: token, data: data, maxBytes: maxBytes) }
                }
            }
        }

        processes[token] = process
        handleForPID[pid] = token

        // Capture the launch identity for the ownership ledger. The census must
        // prove ownership against THIS identity — it is never regenerated later.
        // The process just launched and must be present; if its identity cannot
        // be established the ledger stays absent and the census fails closed.
        switch HostProcessLineage.probe(pid: pid) {
        case .present(let snap):
            rootIdentityByToken[token] = snap.identity
        case .confirmedExited, .inaccessible, .providerFailure:
            rootIdentityByToken[token] = nil
        }

        return SupervisedProcessHandle(
            token: token,
            pid: pid,
            startedAt: Date()
        )
    }

    // MARK: - Query

    /// Check if a process is still alive.
    func isAlive(_ handle: SupervisedProcessHandle) -> Bool {
        guard let process = processes[handle.token] else { return false }
        return process.isRunning
    }

    /// Get the handle for a given PID, if owned by this supervisor.
    func handleForPID(_ pid: Int32) -> SupervisedProcessHandle? {
        guard let token = handleForPID[pid],
              let process = processes[token] else { return nil }
        return SupervisedProcessHandle(
            token: token,
            pid: process.processIdentifier,
            startedAt: Date() // approximate
        )
    }

    /// The root identity captured when this handle's process was launched.
    /// This is the authoritative ownership root for the census ledger.
    func capturedRootIdentity(for handle: SupervisedProcessHandle) -> ProcessIdentity? {
        rootIdentityByToken[handle.token]
    }

    // MARK: - Control

    /// Send a normal termination request (SIGTERM via `terminate()`).
    func requestTerminate(_ handle: SupervisedProcessHandle) async {
        guard let process = processes[handle.token], process.isRunning else { return }
        process.terminate()
    }

    /// Send SIGKILL — only allowed when the handle is owned.
    func requestForceKill(_ handle: SupervisedProcessHandle) async throws {
        guard let process = processes[handle.token] else {
            throw ProcessSupervisorError.handleNotFound(handle.token)
        }
        guard process.isRunning else { return }
        guard process.processIdentifier == handle.pid else {
            throw ProcessSupervisorError.pidMismatch(
                owned: process.processIdentifier,
                requested: handle.pid
            )
        }
        kill(handle.pid, SIGKILL)
    }

    /// Wait for a process to exit, with timeout.
    ///
    /// Exactly-once resume is guaranteed by `ProcessExitWaiter`; both the
    /// termination handler and the timeout race to `finish`, which never
    /// resumes the continuation twice. The waiter retains itself until it
    /// finishes so the continuation always has a live reference.
    func waitForExit(
        _ handle: SupervisedProcessHandle,
        timeout: Duration
    ) async -> ProcessWaitOutcome {
        guard let process = processes[handle.token] else {
            return .exited(0) // already gone
        }
        guard process.isRunning else {
            return .exited(process.terminationStatus)
        }

        return await withCheckedContinuation { continuation in
            _ = ProcessExitWaiter(
                process: process,
                timeout: timeout,
                continuation: continuation
            )
        }
    }

    /// Wait for a process to exit, without timeout.
    /// Blocks until termination. Use for installer where the user controls duration.
    func waitForTermination(
        _ handle: SupervisedProcessHandle
    ) async -> ProcessWaitOutcome {
        guard let process = processes[handle.token] else {
            return .exited(0)
        }
        return await withCheckedContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: .exited(process.terminationStatus))
                return
            }
            _ = ProcessExitWaiter(
                process: process,
                timeout: nil,
                continuation: continuation
            )
        }
    }

    /// Append bounded diagnostic output from a process.
    private func appendOutput(token: UUID, data: Data, maxBytes: Int) {
        var buffer = outputBuffers[token] ?? Data()
        buffer.append(data)
        if buffer.count > maxBytes {
            buffer = buffer.suffix(maxBytes)
        }
        outputBuffers[token] = buffer
    }

    /// Cleanup — remove internal bookkeeping for a completed process.
    func discard(_ handle: SupervisedProcessHandle) {
        guard let process = processes.removeValue(forKey: handle.token) else { return }
        handleForPID.removeValue(forKey: handle.pid)
        outputBuffers.removeValue(forKey: handle.token)
        rootIdentityByToken.removeValue(forKey: handle.token)
        // Clear readability handlers to avoid leaks
        if let out = process.standardOutput as? Pipe {
            out.fileHandleForReading.readabilityHandler = nil
        }
        if let err = process.standardError as? Pipe {
            err.fileHandleForReading.readabilityHandler = nil
        }
    }
}

/// Helper to manage Process termination handler with Sendable safety.
/// Exactly-once resume: both the termination handler and the deadline race to
/// `finish`, and only the first call resumes the continuation.
///
/// The waiter retains itself until `finish` so the continuation always has a
/// live reference (a deallocated waiter would leak the continuation and hang
/// the caller forever).
final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<ProcessWaitOutcome, Never>?
    private weak var process: Process?
    private var deadlineWork: DispatchWorkItem?
    private var selfRetain: ProcessExitWaiter?

    init(
        process: Process,
        timeout: Duration?,
        continuation: CheckedContinuation<ProcessWaitOutcome, Never>,
        launch: (() throws -> Void)? = nil
    ) {
        self.process = process
        self.continuation = continuation
        self.selfRetain = self

        // Install termination handler BEFORE launch so a process that exits
        // immediately can never escape the handler (exit-before-install race).
        process.terminationHandler = { [weak self] proc in
            self?.finish(.exited(proc.terminationStatus))
        }

        // Launch now if this waiter owns the run() call.
        if let launch {
            do {
                try launch()
            } catch {
                self.finish(.exited(0))
                return
            }
        }

        // Re-check after launch/install: the process may have exited before
        // the handler could fire. Resume with the current status.
        if !process.isRunning {
            self.finish(.exited(process.terminationStatus))
            return
        }

        // Deadline that also resumes the continuation.
        guard let timeout else { return }
        let nanos = timeout.components.seconds * 1_000_000_000
            + timeout.components.attoseconds / 1_000_000_000
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.timedOut)
        }
        deadlineWork = work
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .nanoseconds(Int(nanos)),
            execute: work
        )
    }

    private func finish(_ outcome: ProcessWaitOutcome) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()

        deadlineWork?.cancel()
        deadlineWork = nil
        process?.terminationHandler = nil
        selfRetain = nil
        continuation.resume(returning: outcome)
    }
}
