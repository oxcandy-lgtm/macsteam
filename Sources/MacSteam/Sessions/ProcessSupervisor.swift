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
        "WINEPREFIX", "WINEARCH", "WINEDEBUG",
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

/// Owns child `Process` objects on behalf of `GameSessionSupervisor`.
///
/// **U1R7:** The `Process` references live exclusively inside this actor.
/// No other type may hold a `Process` value.  Handles (`SupervisedProcessHandle`)
/// are passed outward instead.
actor ProcessSupervisor {

    private var processes: [UUID: Process] = [:]
    private var handleForPID: [Int32: UUID] = [:]

    // MARK: - Launch

    /// Launch a child process from the given plan.
    ///
    /// - Throws: `ProcessSupervisorError` on any failure.
    func launch(plan: LaunchPlan) async throws -> SupervisedProcessHandle {
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Launch
        try process.run()

        let token = UUID()
        let pid = process.processIdentifier
        guard pid > 0 else {
            throw ProcessSupervisorError.launchFailed("PID is 0 or negative")
        }

        processes[token] = process
        handleForPID[pid] = token

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
    /// Uses `terminationHandler` continuation + `Task.sleep` race.
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

        return await withTaskGroup(of: ProcessWaitOutcome.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let handler = ProcessTerminationHandler(process: process, continuation: continuation)
                    handler.install()
                }
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                return ProcessWaitOutcome.timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()

            if case .timedOut = first {
                process.terminationHandler = nil
            }

            return first
        }
    }

    /// Cleanup — remove internal bookkeeping for a completed process.
    func discard(_ handle: SupervisedProcessHandle) {
        processes.removeValue(forKey: handle.token)
        handleForPID.removeValue(forKey: handle.pid)
    }
}

/// Helper to manage Process termination handler with Sendable safety.
private final class ProcessTerminationHandler: @unchecked Sendable {
    weak var process: Process?
    let continuation: CheckedContinuation<ProcessWaitOutcome, Never>

    init(process: Process, continuation: CheckedContinuation<ProcessWaitOutcome, Never>) {
        self.process = process
        self.continuation = continuation
    }

    func install() {
        process?.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.process?.terminationHandler = nil
            self.continuation.resume(returning: .exited(proc.terminationStatus))
        }
    }
}
