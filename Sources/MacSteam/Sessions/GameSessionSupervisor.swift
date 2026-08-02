// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@MainActor
protocol GameSessionSupervising: AnyObject {
    var state: GameSessionState { get }
    var activeSession: GameSession? { get }
    var isRunning: Bool { get }
    var isStopping: Bool { get }
    var needsRecovery: Bool { get }

    func launch(
        plan: LaunchPlan,
        runtimeControl: any WineRuntimeControl,
        prefixRoot: URL,
        recipeID: String,
        runtimeID: String,
        purpose: SessionPurpose
    ) async throws -> GameSession

    func stop() async throws

    /// Produce the process census for the active session.
    ///
    /// Ownership is rooted in the launch-captured identity held in the session
    /// ledger (not regenerated at census time) and only ever admits observed
    /// descendants. Fails closed: `.incomplete` / `notProven` on any provider
    /// failure, missing acquisition, root drift, or bound violation.
    func processCensus() async -> ProcessCensusResult
}

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

/// Process-control surface the cleanup transaction drives.
///
/// Conformed to by the production `ProcessSupervisor` actor and by test fakes
/// that count calls and script reap outcomes, so the cleanup invariants
/// (reap-before-discard, halt-on-unconfirmed, no re-run on retry) are provable
/// behaviorally — not by inspecting comments or identifiers.
protocol CleanupProcessControlling: Sendable {
    func requestTerminate(_ handle: SupervisedProcessHandle) async
    func requestForceKill(_ handle: SupervisedProcessHandle) async throws
    func waitForExit(_ handle: SupervisedProcessHandle, timeout: Duration) async -> ProcessWaitOutcome
    func discard(_ handle: SupervisedProcessHandle) async
}

/// Wineserver-control surface the cleanup transaction drives.
///
/// Conformed to by the production `WineServerController` actor and by test
/// fakes that script shutdown failure / still-running outcomes.
protocol CleanupWineServerControlling: Sendable {
    func shutdownPrefix(runtime: any WineRuntimeControl, prefix: URL, waitSeconds: Int) async throws -> Bool
    func isRunning(prefix: URL, runtime: any WineRuntimeControl) async throws -> Bool
}

extension ProcessSupervisor: CleanupProcessControlling {}
extension WineServerController: CleanupWineServerControlling {}

/// The callable recovery authority for a `.recoveryRequired` supervisor.
///
/// Bundles the cleanup payload — the owned process handle, the held prefix
/// lock, the runtime control, and the prefix context — together with how far a
/// single forward cleanup transaction has progressed. It is guaranteed to be
/// non-nil whenever `state == .recoveryRequired`, so a cleanup can always be
/// re-entered and re-run even after the session object itself is gone, without
/// ever re-acquiring a handle from the PID/process table.
struct RecoveryCleanupAuthority: Sendable {
    let processHandle: SupervisedProcessHandle?
    let sessionLock: SessionLock?
    let runtimeControl: LiveRuntimeControl?
    let prefix: URL

    /// Progress of the single forward cleanup transaction. A retry resumes
    /// from where the authority indicates, never skipping ahead: the process
    /// is only discarded after its reap is confirmed and the lock is only
    /// released after the full cleanup (incl. wineserver shutdown) verifies.
    var reapConfirmed: Bool = false
    var processDiscarded: Bool = false
    var wineserverShutdown: Bool = false

    var isFullyCleaned: Bool {
        // No process left running unconfirmed, no bookkeeping retained, and
        // the wineserver is confirmed down.
        (handleNeedsCleanup == false) && !hasRetainedLock
    }

    /// Whether a process still needs a reap-confirmed discard.
    var handleNeedsCleanup: Bool { reapConfirmed == false && processDiscarded == false }

    /// Whether the prefix lock is still held and must be released last.
    var hasRetainedLock: Bool { sessionLock?.isHeld == true }
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
    private let windowObserver: SessionWindowObserver

    /// Cleanup-transaction control surface. Defaults to the production actors;
    /// injectable so the cleanup invariants are provable with counting fakes.
    /// Launch/census keep using the concrete actors above; only the forward
    /// cleanup transaction routes through these seams.
    private let cleanupProcesses: any CleanupProcessControlling
    private let cleanupWineserver: any CleanupWineServerControlling

    /// Session-scoped ownership ledger, seeded from the ProcessSupervisor-
    /// captured root identity at launch. Reset on every launch/stop so stale
    /// observations from a previous session are never reused.
    private var censusLedger: ProcessCensusLedger?

    private var sessionLock: SessionLock?

    /// The retained cleanup authority for a `.recoveryRequired` state.
    ///
    /// Invariant: this is non-nil whenever `state == .recoveryRequired`, so a
    /// stop/force-stop retry always has a callable authority and never no-ops
    /// because `activeSession == nil`.
    private var recoveryCleanup: RecoveryCleanupAuthority?
    private var launchCommitted = false

    init(
        windowProvider: any WindowInfoProviding = WindowServerProvider(),
        cleanupProcesses: (any CleanupProcessControlling)? = nil,
        cleanupWineserver: (any CleanupWineServerControlling)? = nil
    ) {
        self.windowObserver = SessionWindowObserver(provider: windowProvider)
        self.cleanupProcesses = cleanupProcesses ?? processSupervisor
        self.cleanupWineserver = cleanupWineserver ?? wineserverController
    }

    // MARK: - Validation

    /// Validate that a launch plan is suitable for a supervised session.
    static func validateSessionPlan(_ plan: LaunchPlan) throws {
        guard plan.mode == .supervisedSession else {
            throw SessionSupervisorError.validationFailed(
                "Session launch requires supervisedSession mode"
            )
        }
    }

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
        try Self.validateSessionPlan(plan)

        guard state == .idle || state == .stopped else {
            let pid = activeSession?.rootPID ?? 0
            throw SessionSupervisorError.sessionAlreadyRunning(existingPID: pid)
        }

        windowObserver.invalidate()

        // Mark launching immediately
        state = .launching
        launchCommitted = false
        activeSession = nil
        activeHandle = nil
        activeRuntimeControl = nil
        censusLedger = nil

        // Rollback closure: reset on failure. A recovery state that was explicitly
        // set (e.g. an unconfirmed force-kill reap) is preserved — rollback never
        // claims success that did not happen. In recovery the cleanup authority
        // is captured (before the session fields are cleared) and OWNS the held
        // lock, so the lock is NOT released here — it is released only at the
        // cleanup transaction's terminal step.
        defer {
            if !launchCommitted {
                windowObserver.invalidate()
                if case .recoveryRequired = state {
                    // Recovery: retain a callable authority and keep the lock it
                    // owns. Never release the lock on the recovery rollback.
                    if recoveryCleanup == nil {
                        recoveryCleanup = RecoveryCleanupAuthority(
                            processHandle: activeHandle,
                            sessionLock: sessionLock,
                            runtimeControl: activeRuntimeControl,
                            prefix: prefixRoot
                        )
                    }
                    activeSession = nil
                    activeHandle = nil
                    activeRuntimeControl = nil
                    censusLedger = nil
                    // sessionLock intentionally retained: owned by the authority.
                } else {
                    sessionLock?.release()
                    sessionLock = nil
                    activeSession = nil
                    activeHandle = nil
                    activeRuntimeControl = nil
                    censusLedger = nil
                    state = .idle
                }
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

        // Seed the ownership ledger with the launch-captured root identity.
        // Fail-closed: an identity-less handle/session/receipt/ledger must never
        // be published. If the launch identity cannot be established, terminate
        // and reap the launched process, delete every bit of bookkeeping, and
        // fail the launch (the rollback defer releases the lock and resets
        // state to idle).
        guard let rootIdentity = await processSupervisor.capturedRootIdentity(for: handle) else {
            let confirmed = await terminateAndReapOwned(handle)
            if confirmed {
                await processSupervisor.discard(handle)
            }
            // If the force-kill was not confirmed, do NOT claim a complete
            // rollback: retain cleanup authority in an explicit recovery state
            // so the orphaned process can still be reaped.
            if !confirmed {
                state = .recoveryRequired(
                    "The launched process identity could not be established and its reap was unconfirmed; process cleanup requires recovery"
                )
            }
            throw SessionSupervisorError.launchFailed(
                "The launched process identity could not be established; aborted to avoid an unproven session"
            )
        }
        self.censusLedger = ProcessCensusLedger(rootIdentity: rootIdentity)

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
        startWindowMonitor()

        return session
    }

    // MARK: - Stop

    /// Terminate an owned process and contend its reap: SIGTERM, bounded wait;
    /// on timeout SIGKILL, then a second bounded wait to confirm the reap.
    /// Returns `true` only when the process is confirmed gone. A force-killed
    /// but unconfirmed process returns `false` — the caller must NOT claim a
    /// complete rollback and must retain cleanup authority for recovery.
    @MainActor
    private func terminateAndReapOwned(_ handle: SupervisedProcessHandle) async -> Bool {
        await cleanupProcesses.requestTerminate(handle)
        if case .timedOut = await cleanupProcesses.waitForExit(handle, timeout: .seconds(2)) {
            try? await cleanupProcesses.requestForceKill(handle)
            // SIGKILL must itself be contended by a second bounded reap-wait —
            // a silent force-kill that never reaps is not a confirmed cleanup.
            if case .timedOut = await cleanupProcesses.waitForExit(handle, timeout: .seconds(2)) {
                return false
            }
        }
        return true
    }

    /// Rebuild the cleanup authority to drive teardown: the retained recovery
    /// authority if this is a retry, otherwise the live session/process/lock.
    ///
    /// A retry never re-acquires the process from the PID table: it reuses the
    /// retained `SupervisedProcessHandle`. A fresh stop derives the authority
    /// from the live, launch-captured state.
    private func currentCleanupAuthority() -> RecoveryCleanupAuthority? {
        if let retained = recoveryCleanup { return retained }
        guard let session = activeSession else { return nil }
        return RecoveryCleanupAuthority(
            processHandle: activeHandle,
            sessionLock: sessionLock,
            runtimeControl: activeRuntimeControl,
            prefix: session.prefixRoot
        )
    }

    /// Retain the cleanup authority when a stop/force-stop is unconfirmed.
    /// The authority (and the process/lock it carries) is never deleted just
    /// because the attempt failed — it stays callable for the next retry.
    ///
    /// A retry must reuse the retained authority respecting its progress
    /// (reap/Discard flags), never re-acquire from the PID table, and never
    /// skip-ahead past an unconfirmed step.
    private func enterRecovery(_ message: String) {
        state = .recoveryRequired(message)
    }

    /// Test seam: install a recovery authority directly so the cleanup
    /// invariants can be exercised behaviorally (with counting fakes) without a
    /// live launch. Internal only — not part of the public supervising API.
    func installRecoveryAuthorityForTesting(_ authority: RecoveryCleanupAuthority) {
        self.recoveryCleanup = authority
        self.state = .recoveryRequired("test-installed recovery authority")
    }

    /// Test seam: read the stored cleanup authority so persistence/retention
    /// invariants can be asserted. Internal only.
    var recoveryCleanupForTesting: RecoveryCleanupAuthority? { recoveryCleanup }

    /// Run the full, single-forward cleanup transaction.
    ///
    /// The authoritative record is the STORED `recoveryCleanup` itself — never a
    /// detached local copy. Each completed step is persisted to it immediately,
    /// so a retry resumes exactly where the last attempt stopped and never
    /// re-runs a confirmed step.
    ///
    /// Order: TERM → bounded wait → SIGKILL (if needed) → second reap-confirm
    /// wait → discard (only once confirmed) → wineserver shutdown + stopped
    /// confirm → release the authority-owned lock (last, once) → delete
    /// receipt/bookkeeping → clear the authority → `.stopped`.
    ///
    /// If the reap is unconfirmed, the transaction HALTS: discard, wineserver,
    /// lock release, and authority clear all execute zero times, and the
    /// authority is retained for a later retry.
    @MainActor
    private func runCleanupTransaction(force: Bool) async throws {
        windowObserver.invalidate()
        guard var authority = recoveryCleanup else { return }

        // Phase 1 — reap-confirm the owned process. Persist the outcome at
        // once. On an unconfirmed reap, stop the whole transaction here.
        if let handle = authority.processHandle, !authority.processDiscarded {
            let confirmed = await terminateAndReapOwned(handle)
            authority.reapConfirmed = confirmed
            recoveryCleanup = authority                       // persist immediately
            guard confirmed else {
                // Reap unconfirmed: no discard / wineserver / lock-release /
                // authority-clear may run. The retained authority is the only
                // cleanup record; a retry re-contends the reap.
                throw SessionSupervisorError.stopIncomplete(
                    "process reap unconfirmed; cleanup halted before discard/wineserver/lock-release"
                )
            }
            await cleanupProcesses.discard(handle)
            authority.processDiscarded = true
            recoveryCleanup = authority                       // persist immediately
        }

        // Phase 2 — wineserver shutdown + stopped confirmation. A failure here
        // retains the already-persisted reap/discard progress for the retry.
        if let runtime = authority.runtimeControl?.control, !authority.wineserverShutdown {
            do {
                _ = try await cleanupWineserver.shutdownPrefix(
                    runtime: runtime,
                    prefix: authority.prefix,
                    waitSeconds: 10
                )
            } catch let error as WineServerError {
                recoveryCleanup = authority                   // keep reap/discard progress
                throw SessionSupervisorError.stopIncomplete(error.localizedDescription)
            }
            let stillRunning = try await cleanupWineserver.isRunning(
                prefix: authority.prefix,
                runtime: runtime
            )
            guard !stillRunning else {
                recoveryCleanup = authority                   // keep reap/discard progress
                throw SessionSupervisorError.stopIncomplete(
                    "wineserver is still running after shutdown request"
                )
            }
            authority.wineserverShutdown = true
            recoveryCleanup = authority                       // persist immediately
        }

        // Phase 3 — terminal. Release ONLY the authority-owned lock, exactly
        // once; then delete receipt/bookkeeping; then clear the authority.
        authority.sessionLock?.release()
        try? receiptStore.remove(prefix: authority.prefix)
        recoveryCleanup = nil
        sessionLock = nil
        activeSession = nil
        activeHandle = nil
        activeRuntimeControl = nil
        censusLedger = nil
        state = .stopped
    }

    /// Stop the active session completely.
    ///
    /// Drives the single forward cleanup transaction from the stored authority.
    /// On success the authority is cleared and state → `.stopped`. On any
    /// failure the authority (with its persisted progress) is retained and
    /// state → `.recoveryRequired`, so a subsequent stop/force-stop resumes
    /// instead of no-op'ing on a nil `activeSession`.
    func stop() async throws {
        state = .stopping
        if recoveryCleanup == nil {
            recoveryCleanup = currentCleanupAuthority()
        }
        do {
            try await runCleanupTransaction(force: false)
        } catch {
            enterRecovery("Stop failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Force stop — only for UI-initiated Force Stop after normal stop fails.
    func forceStop() async throws {
        state = .stopping
        if recoveryCleanup == nil {
            recoveryCleanup = currentCleanupAuthority()
        }
        do {
            try await runCleanupTransaction(force: true)
        } catch {
            enterRecovery("Force stop failed: \(error.localizedDescription)")
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
            censusLedger = nil
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
                    censusLedger = nil
                    state = .idle
                }

            case .game:
                // Game: adopt session as before
                let lock = try SessionLock(prefix: prefix)
                let acquired = try lock.acquire()
                self.sessionLock = lock
                _ = acquired // silence unused-result warning

                // Recovery has no ProcessSupervisor-captured root identity, so
                // the ownership ledger stays absent: the census is fail-closed
                // (incomplete / notProven) rather than fabricating one.
                self.censusLedger = nil
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
                startWindowMonitor()
            }
        } else {
            // Receipt exists but server is stopped → stale receipt
            receiptStore.remove(prefix: prefix)
            censusLedger = nil
            state = .idle
        }
    }

    // MARK: - Window observation

    private func startWindowMonitor() {
        guard let session = activeSession else { return }
        let target = WindowTarget.derive(purpose: session.purpose, recipeID: session.recipeID)
        let sessionID = session.sessionID
        windowObserver.startMonitoring(
            sessionID: sessionID,
            target: target,
            applyState: { [weak self] observedState in
                guard let self = self else { return }
                guard self.activeSession?.sessionID == sessionID else { return }
                self.applyWindowObservation(observedState)
            }
        )
    }

    private func applyWindowObservation(_ observedState: GameSessionState) {
        switch state {
        case .runningUnknown, .runningVisible, .runningHidden:
            state = observedState
        default:
            break
        }
    }

    // MARK: - Query

    /// Produce the process census from the session-scoped ownership ledger.
    ///
    /// Fails closed: with no active session ledger (no session, failed launch
    /// capture, or recovery) the census is `.incomplete` and the diagnostic
    /// reports `notProven`.
    func processCensus() async -> ProcessCensusResult {
        guard var ledger = censusLedger else {
            return .incomplete(.noLedger)
        }
        let result = HostProcessLineage.census(ledger: &ledger)
        censusLedger = ledger
        return result
    }

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

    var sessionAlreadyRunning: Bool { isRunning }

    var isWindowMonitoring: Bool { windowObserver.isMonitoring }
}

extension GameSessionSupervisor: GameSessionSupervising {}
