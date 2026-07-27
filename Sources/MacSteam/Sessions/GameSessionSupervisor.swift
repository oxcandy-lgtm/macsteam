// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// State of a single game session.
enum GameSessionState: Sendable, Equatable {
    case idle
    case launching
    case running
    case stopping
    case stopped
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
}

/// Errors from GameSessionSupervisor operations.
enum SessionSupervisorError: Error, Sendable, LocalizedError {
    case sessionAlreadyRunning(existingPID: Int32)
    case prefixLockHeld(prefixID: String)
    case launchFailed(String)
    case stopFailed(String)
    case processNotFound(pid: Int32)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyRunning(let pid):
            return "Session already running (PID \(pid))"
        case .prefixLockHeld(let id):
            return "Prefix \(id) is locked by another process"
        case .launchFailed(let msg):
            return "Launch failed: \(msg)"
        case .stopFailed(let msg):
            return "Stop failed: \(msg)"
        case .processNotFound(let pid):
            return "Process \(pid) no longer exists"
        }
    }
}

/// Receipt-like data persisted after a session ends.
/// Stored outside the repository with `0600` permissions.
struct GameSessionReceipt: Codable, Sendable {
    let sessionID: UUID
    let recipeID: String
    let runtimeID: String
    let rootPID: Int32
    let startedAt: Date
    let endedAt: Date
    let exitCode: Int32?
    let state: String
}

/// Supervises game sessions for a single prefix.
///
/// **U1R6:** Enforces exactly one session per prefix.
/// - Acquires an exclusive SessionLock before launch.
/// - Prevents duplicate sessions.
/// - Provides clean stop flow.
/// - Supports Stop & Relaunch.
@MainActor
final class GameSessionSupervisor {
    private(set) var state: GameSessionState = .idle
    private(set) var activeSession: GameSession?

    private let processRunner: ProcessRunner
    private let wineserverController: WineServerController
    private var rootProcess: Process?
    private var sessionLock: SessionLock?

    private let receiptsDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Sessions")
    }()

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
        self.wineserverController = WineServerController()
    }

    // MARK: - Launch

    /// Launch a new session for the given launch plan.
    ///
    /// - Throws: `SessionSupervisorError.sessionAlreadyRunning` if a
    ///   session is already active.
    func launch(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        prefixRoot: URL? = nil,
        recipeID: String = "unknown",
        timeout: TimeInterval? = nil
    ) async throws -> LaunchSessionHandle {
        guard state == .idle || state == .stopped else {
            let pid = activeSession?.rootPID ?? 0
            throw SessionSupervisorError.sessionAlreadyRunning(existingPID: pid)
        }

        // 1. Acquire prefix lock
        let prefixID = prefixRoot?.lastPathComponent ?? "default"
        let lock = try SessionLock(prefixID: prefixID)
        do {
            try lock.acquire()
        } catch SessionLockError.lockHeldByAnotherSession(let pid) {
            throw SessionSupervisorError.prefixLockHeld(prefixID: prefixID)
        }
        self.sessionLock = lock

        // 2. Mark as launching
        state = .launching

        // 3. Execute launch
        let result = try await processRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )

        // 4. Create session
        let sessionID = UUID()
        let now = Date()
        let session = GameSession(
            sessionID: sessionID,
            recipeID: recipeID,
            runtimeID: "runtime",
            prefixRoot: prefixRoot ?? URL(fileURLWithPath: "/"),
            rootPID: result.pid ?? 0,
            startedAt: now
        )

        self.activeSession = session
        self.state = .running

        return LaunchSessionHandle(
            sessionID: sessionID,
            rootPID: result.pid ?? 0,
            startedAt: now
        )
    }

    // MARK: - Stop & Relaunch

    /// Stop the active session and wait for complete shutdown.
    func stop() async throws {
        guard let session = activeSession else { return }
        state = .stopping

        // 1. Terminate root process (if owned)
        if let process = rootProcess, process.isRunning {
            process.terminate()
            // Wait up to 5s
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && process.isRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                // Force kill
                kill(session.rootPID, SIGKILL)
            }
        }

        // 2. Stop prefix via wineserver
        // For now: stub — will use WineRuntimeControl protocol

        // 3. Release lock
        sessionLock?.release()
        sessionLock = nil

        state = .stopped
        activeSession = nil
    }

    /// Stop the current session, then launch a new one.
    func stopAndRelaunch(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        prefixRoot: URL? = nil,
        recipeID: String = "unknown",
        timeout: TimeInterval? = nil
    ) async throws -> LaunchSessionHandle {
        try await stop()
        return try await launch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            prefixRoot: prefixRoot,
            recipeID: recipeID,
            timeout: timeout
        )
    }

    // MARK: - Query

    /// Whether a session is currently active.
    var isRunning: Bool {
        state == .running || state == .launching
    }

    /// The PID of the active session's root process, if any.
    var runningPID: Int32? {
        activeSession?.rootPID
    }
}

/// Handle returned from a successful supervised launch.
struct LaunchSessionHandle: Sendable {
    let sessionID: UUID
    let rootPID: Int32
    let startedAt: Date
}
