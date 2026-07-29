// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// State of a single game session.
enum GameSessionState: Sendable, Equatable {
    case idle
    case launching
    case runningUnknown
    case runningVisible
    case runningHidden
    case stopping
    case stopped
    case recoveryRequired(String)
    case failed(String)
}

/// A single game session bound to one prefix.
struct GameSession: Sendable, Equatable {
    let sessionID: UUID
    let recipeID: String
    let runtimeID: String
    let prefixRoot: URL
    let rootPID: Int32
    let startedAt: Date
    let purpose: SessionPurpose
}

/// A persistent (non-codable) holder for a live session's runtime control.
struct LiveRuntimeControl: Sendable {
    let control: any WineRuntimeControl
}

/// Errors from GameSessionSupervisor operations.
enum SessionSupervisorError: Error, Sendable, LocalizedError {
    case sessionAlreadyRunning(existingPID: Int32)
    case prefixLockHeld(URL)
    case launchFailed(String)
    case stopFailed(String)
    case stopIncomplete(String)
    case processNotFound(pid: Int32)
    case recoveryBlocked(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyRunning(let pid):
            return "Session already running (PID \(pid))"
        case .prefixLockHeld(let url):
            return "Prefix \(url.lastPathComponent) is locked by another process"
        case .launchFailed(let msg):
            return "Launch failed: \(msg)"
        case .stopFailed(let msg):
            return "Stop failed: \(msg)"
        case .stopIncomplete(let msg):
            return "Stop did not complete: \(msg)"
        case .processNotFound(let pid):
            return "Process \(pid) no longer exists"
        case .recoveryBlocked(let msg):
            return "Recovery blocked: \(msg)"
        case .validationFailed(let msg):
            return "Validation failed: \(msg)"
        }
    }
}

/// Supervises game sessions for a single prefix.
///
/// **U1R7:**
/// - Enforces exactly one session per prefix via `SessionLock`.
/// - Uses `ProcessSupervisor` for Process ownership (no raw Process objects outside).
/// - Stop flow: terminate → wait → wineserver -k → wineserver -w → lock release.
/// - Lock is not released until session is fully stopped.
/// - Launch failure always releases the lock and resets state.
@MainActor
final class GameSessionSupervisor {
    private(set) var state: GameSessionState = .idle
    private(set) var activeSession: GameSession?
    private(set) var activeHandle: SupervisedProcessHandle?
    private(set) var activeRuntimeControl: LiveRuntimeControl?

    private let processSupervisor = ProcessSupervisor()
    private let wineserverController = WineServerController()
    private let receiptStore = SessionReceiptStore()

    private var sessionLock: SessionLock?
    private var launchCommitted = false

    // MARK: - Launch

    /// Launch a new session.
    ///
    /// Flow:
    /// 1. Canonical prefix validation + prefix ID derivation
    /// 2. SessionLock acquisition
    /// 3. ProcessSupervisor launch
    /// 4. 5-second liveness check (process alive OR wineserver running)
    /// 5. State = runningUnknown
    ///
    /// On any failure: lock is released, state → idle.
    func launch(
        plan: LaunchPlan,
        runtimeControl: any WineRuntimeControl,
        prefixRoot: URL,
        recipeID: String,
        runtimeID: String,
        purpose: SessionPurpose = .game
    ) async throws -> GameSession {
        guard state == .idle || state == .stopped else {
            let pid = activeSession?.rootPID ?? 0
            throw SessionSupervisorError.sessionAlreadyRunning(existingPID: pid)
        }

        // Mark launching immediately
        state = .launching
        launchCommitted = false
        activeSession = nil
        activeHandle = nil
        activeRuntimeControl = nil

        // Rollback closure: release lock + reset on failure
        defer {
            if !launchCommitted {
                sessionLock?.release()
                sessionLock = nil
                activeSession = nil
                activeHandle = nil
                activeRuntimeControl = nil
                state = .idle
            }
        }

        // 1. SessionLock
        let lock = try SessionLock(prefix: prefixRoot)
        do {
            try lock.acquire()
        } catch SessionLockError.lockHeldByAnotherSession(let pid) {
            throw SessionSupervisorError.prefixLockHeld(prefixRoot)
        }
        self.sessionLock = lock

        // 2. Launch via ProcessSupervisor
        let handle = try await processSupervisor.launch(plan: plan)
        self.activeHandle = handle
        self.activeRuntimeControl = LiveRuntimeControl(control: runtimeControl)

        // 3. 5-second liveness check
        let deadline = Date().addingTimeInterval(5)
        var livenessConfirmed = false
        while Date() < deadline {
            let processAlive = await processSupervisor.isAlive(handle)
            let serverAlive = try await wineserverController.isRunning(
                prefix: prefixRoot,
                runtime: runtimeControl
            )

            if processAlive || serverAlive {
                livenessConfirmed = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        guard livenessConfirmed else {
            throw SessionSupervisorError.launchFailed(
                "Runtime exited before session became active"
            )
        }

        // 4. Create session
        let session = GameSession(
            sessionID: UUID(),
            recipeID: recipeID,
            runtimeID: runtimeID,
            prefixRoot: prefixRoot,
            rootPID: handle.pid,
            startedAt: Date(),
            purpose: purpose
        )

        self.activeSession = session
        launchCommitted = true

        // 5. Write receipt
        try receiptStore.write(session: session, state: .runningUnknown)

        // 6. Final state
        state = .runningUnknown

        return session
    }

    // MARK: - Stop

    /// Stop the active session completely.
    ///
    /// Flow:
    /// 1. Terminate owned root process (normal request)
    /// 2. Wait up to 5 seconds for process exit
    /// 3. wineserver -k (shutdown request)
    /// 4. wineserver -w with 10s timeout (wait for server exit)
    /// 5. Verify isRunning == false
    /// 6. Remove receipt
    /// 7. Release lock
    /// 8. State → stopped
    func stop() async throws {
        guard let session = activeSession else { return }
        state = .stopping

        do {
            // 1. Terminate owned root process
            if let handle = activeHandle {
                await processSupervisor.requestTerminate(handle)

                // Wait up to 5 seconds
                let outcome = await processSupervisor.waitForExit(
                    handle,
                    timeout: .seconds(5)
                )

                // If still alive after timeout, the stop continues with wineserver
                if case .timedOut = outcome {
                    // Not forcing SIGKILL — let wineserver cleanup handle it
                }
            }

            // 2. Shutdown wineserver
            guard let runtimeControl = activeRuntimeControl else {
                throw SessionSupervisorError.stopFailed("No runtime control available")
            }

            do {
                try await wineserverController.shutdownPrefix(
                    runtime: runtimeControl.control,
                    prefix: session.prefixRoot,
                    waitSeconds: 10
                )
            } catch let error as WineServerError {
                throw SessionSupervisorError.stopIncomplete(error.localizedDescription)
            }

            // 3. Verify complete shutdown
            let stillRunning = try await wineserverController.isRunning(
                prefix: session.prefixRoot,
                runtime: runtimeControl.control
            )

            if stillRunning {
                throw SessionSupervisorError.stopIncomplete(
                    "wineserver is still running after shutdown request"
                )
            }

            // 4. Success — cleanup
            try? receiptStore.remove(prefix: session.prefixRoot)
            sessionLock?.release()
            sessionLock = nil
            activeSession = nil
            activeHandle = nil
            activeRuntimeControl = nil
            state = .stopped
        } catch {
            state = .recoveryRequired("Stop failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Force stop — only for UI-initiated Force Stop after normal stop fails.
    func forceStop() async throws {
        guard let session = activeSession,
              let handle = activeHandle else { return }

        state = .stopping

        do {
            // 1. Force kill owned root process
            try await processSupervisor.requestForceKill(handle)

            // 2. wineserver kill + bounded wait
            if let runtimeControl = activeRuntimeControl {
                try await wineserverController.shutdownPrefix(
                    runtime: runtimeControl.control,
                    prefix: session.prefixRoot,
                    waitSeconds: 10
                )
            }

            // 3. Verify complete shutdown
            guard let runtimeControl = activeRuntimeControl else {
                throw SessionSupervisorError.stopFailed("No runtime control available")
            }
            let stillRunning = try await wineserverController.isRunning(
                prefix: session.prefixRoot,
                runtime: runtimeControl.control
            )

            guard !stillRunning else {
                state = .recoveryRequired("The Wine session is still running.")
                return
            }

            // 4. Success — cleanup
            sessionLock?.release()
            sessionLock = nil
            activeSession = nil
            activeHandle = nil
            activeRuntimeControl = nil
            try? receiptStore.remove(prefix: session.prefixRoot)
            state = .stopped
        } catch {
            state = .recoveryRequired("Force stop failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Stop & Relaunch

    /// Stop the current session, then launch a new one.
    func stopAndRelaunch(
        plan: LaunchPlan,
        runtimeControl: any WineRuntimeControl,
        prefixRoot: URL,
        recipeID: String,
        runtimeID: String,
        purpose: SessionPurpose = .game
    ) async throws -> GameSession {
        try await stop()
        return try await launch(
            plan: plan,
            runtimeControl: runtimeControl,
            prefixRoot: prefixRoot,
            recipeID: recipeID,
            runtimeID: runtimeID,
            purpose: purpose
        )
    }

    // MARK: - Recovery

    /// Attempt to recover a session from an active receipt.
    func recover(prefix: URL, runtimeControl: any WineRuntimeControl) async throws {
        // Check if receipt exists
        guard let receipt = receiptStore.read(prefix: prefix) else {
            state = .idle
            return
        }

        // Check if wineserver is actually running
        let serverRunning = try await wineserverController.isRunning(
            prefix: prefix,
            runtime: runtimeControl
        )

        if serverRunning {
            switch receipt.purpose {
            case .steamInstaller, .steamSetup:
                // SteamSetup/Installer: clean up — don't adopt
                try await wineserverController.shutdownPrefix(
                    runtime: runtimeControl,
                    prefix: prefix,
                    waitSeconds: 10
                )
                // Verify stopped
                let stillRunning = try await wineserverController.isRunning(
                    prefix: prefix,
                    runtime: runtimeControl
                )
                if stillRunning {
                    state = .recoveryRequired("A previous Steam setup session is still running.")
                } else {
                    receiptStore.remove(prefix: prefix)
                    state = .idle
                }

            case .game:
                // Game: adopt session as before
                let lock = try SessionLock(prefix: prefix)
                let acquired = try lock.acquire()
                self.sessionLock = lock
                _ = acquired // silence unused-result warning

                self.activeSession = GameSession(
                    sessionID: receipt.sessionID,
                    recipeID: receipt.recipeID,
                    runtimeID: receipt.runtimeID,
                    prefixRoot: prefix,
                    rootPID: receipt.rootPID,
                    startedAt: receipt.startedAt,
                    purpose: receipt.purpose
                )
                self.activeRuntimeControl = LiveRuntimeControl(control: runtimeControl)
                state = .runningUnknown
            }
        } else {
            // Receipt exists but server is stopped → stale receipt
            receiptStore.remove(prefix: prefix)
            state = .idle
        }
    }

    // MARK: - Session state transitions

    /// User confirmed visible window.
    func confirmWindowVisible() {
        guard case .runningUnknown = state else { return }
        state = .runningVisible
    }

    /// User reported window disappeared (e.g. X button).
    func reportWindowHidden() {
        guard case .runningVisible = state else { return }
        state = .runningHidden
    }

    // MARK: - Query

    var isRunning: Bool {
        switch state {
        case .runningUnknown, .runningVisible, .runningHidden: return true
        default: return false
        }
    }

    var isStopping: Bool {
        if case .stopping = state { return true }
        return false
    }

    var needsRecovery: Bool {
        if case .recoveryRequired = state { return true }
        return false
    }
}
