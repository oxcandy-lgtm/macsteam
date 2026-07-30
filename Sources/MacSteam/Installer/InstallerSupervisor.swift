// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Single-owner supervisor for Steam installation lifecycle.
///
/// Owns the installer process through ``ProcessSupervising`` (injected via the
/// protocol, with ``ProcessSupervisor`` as the default). Transitions through
/// ``InstallerPhase`` via the ``InstallerOperation`` state machine. All phase
/// transitions are validated.
///
/// ## Exit-latch design
///
/// The ``exitLatch`` is created per-launch as the **single authority** for
/// observing the installer process's exit. An ``installExitTask`` calls
/// ``InstallerExitLatch/record(_:)`` when
/// ``ProcessSupervising/waitForTermination(_:)`` returns. Both the normal-exit
/// path (``waitForInstallerExit()``) and the stop path (``stopAndClean()``) read
/// from the latch, guaranteeing that the exit event is observed exactly once.
actor InstallerSupervisor {
    private let processSupervisor: any ProcessSupervising
    private let prefixTerminator: any PrefixProcessTerminating
    private let deadlineScheduler: any DeadlineScheduling
    private var exitLatch: InstallerExitLatch?
    #if DEBUG
    var exitLatchForTesting: InstallerExitLatch? { exitLatch }
    #endif

    private(set) var currentOperation: InstallerOperation?
    private var installExitTask: Task<Void, Never>?
    private var activeHandle: SupervisedProcessHandle?
    private var activeRuntimeURL: URL?
    private var activePrefixURL: URL?
    private var stopRequested = false
    private var finalizedHandleTokens: Set<UUID> = []

    init(
        processSupervisor: any ProcessSupervising = ProcessSupervisor(),
        prefixTerminator: any PrefixProcessTerminating = PrefixProcessTerminator(),
        deadlineScheduler: any DeadlineScheduling = DispatchDeadlineScheduler()
    ) {
        self.processSupervisor = processSupervisor
        self.prefixTerminator = prefixTerminator
        self.deadlineScheduler = deadlineScheduler
    }

    // MARK: - Public API

    /// Start the Steam installation process.
    func startInstaller(
        installerURL: URL,
        runtimeURL: URL,
        prefixURL: URL,
        runtimeSafeID: String,
        prefixSafeID: String
    ) async throws {
        guard currentOperation == nil else {
            throw InstallerError.terminationFailed("Previous installer operation requires cleanup")
        }

        activeRuntimeURL = runtimeURL
        activePrefixURL = prefixURL

        var op = InstallerOperation(
            id: UUID(),
            runtimeSafeID: runtimeSafeID,
            prefixSafeID: prefixSafeID,
            phase: .preflightCleaning,
            startedAt: Date(),
            updatedAt: Date()
        )

        do {
            try op.transition(to: .prefixPreparing)
            self.currentOperation = op

            let layout = WineExecutableLayout.detect(from: runtimeURL)
            let wineURL = layout.wine

            try op.transition(to: .installerLaunching)
            self.currentOperation = op

            let plan = LaunchPlan(
                runtimeExecutable: wineURL,
                arguments: [installerURL.path],
                mode: .waitForExit,
                environment: buildBaseEnv(prefixURL: prefixURL, runtimeURL: runtimeURL),
                workingDirectory: prefixURL
            )

            let handle = try await processSupervisor.launch(plan: plan, outputPolicy: .discard)
            activeHandle = handle

            try op.transition(to: .installerRunning)
            op.updatedAt = Date()
            self.currentOperation = op

            // Per-launch latch: each launch creates a fresh latch so multiple
            // waiters can observe the exit concurrently.
            let latch = InstallerExitLatch(scheduler: deadlineScheduler)
            exitLatch = latch

            installExitTask = Task { [processSupervisor, latch] in
                let outcome = await processSupervisor.waitForTermination(handle)
                await latch.record(outcome)
            }
        } catch {
            op.lastError = error.localizedDescription
            // Silently fall back if the phase is already terminal
            do { try op.transition(to: .interrupted) }
            catch let transitionError {
                op.lastError = "\(error.localizedDescription); state transition failed: \(transitionError.localizedDescription)"
            }
            self.currentOperation = op
            throw error
        }
    }

    /// Wait for the installer to finish.
    ///
    /// Blocks until the installer exits naturally (via the exit latch), then
    /// finalises the handle and transitions the state machine via
    /// ``handleInstallerExit``.
    func waitForInstallerExit() async throws {
        guard let handle = activeHandle, let latch = exitLatch else { return }
        let outcome = await latch.wait()
        try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: false)
    }

    /// Stop the installer and clean up. Fail-closed: if the installer process
    /// does not exit after SIGKILL, state is NOT cleared and an error is thrown.
    func stopAndClean() async throws {
        stopRequested = true

        if let handle = activeHandle, let latch = exitLatch {
            await processSupervisor.requestTerminate(handle)

            if let outcome = await latch.wait(timeout: 5) {
                try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: true)
            } else {
                // Timeout — force kill
                do {
                    try await processSupervisor.requestForceKill(handle)
                } catch {
                    try markCleanupRequired("Force kill failed: \(error.localizedDescription)")
                    throw error
                }
                if let outcome = await latch.wait(timeout: 3) {
                    try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: true)
                } else {
                    try markCleanupRequired("Installer did not exit after SIGKILL")
                    throw InstallerError.terminationFailed("Installer did not exit after SIGKILL")
                }
            }
        }

        guard let runtimeURL = activeRuntimeURL, let prefixURL = activePrefixURL else {
            try markCleanupRequired("Missing runtime or prefix URL")
            throw InstallerError.terminationFailed("Missing runtime or prefix URL")
        }

        let result = await prefixTerminator.terminate(runtimeURL: runtimeURL, prefixURL: prefixURL)
        switch result {
        case .clean:
            stateClear()
        case .incomplete(let reason):
            try markCleanupRequired(reason)
            throw InstallerError.terminationFailed("Prefix cleanup incomplete: \(reason)")
        }
    }

    /// Compatibility wrapper that terminates known prefix processes.
    ///
    /// Provided for call-sites that pass individual process URLs; delegates
    /// to the injected ``prefixTerminator`` directly.
    func stopKnownPrefixProcesses(
        wineExecutable: URL, wineserverURL: URL,
        prefixURL: URL, runtimeURL: URL
    ) async throws {
        let result = await prefixTerminator.terminate(runtimeURL: runtimeURL, prefixURL: prefixURL)
        guard case .clean = result else {
            if case .incomplete(let reason) = result {
                throw InstallerError.terminationFailed(reason)
            }
            return
        }
    }

    /// Snapshot of the current installer state (for UI projection).
    func snapshot() -> InstallerOperation? {
        currentOperation
    }

    /// Exposes the latch waiter count for deterministic test assertions.
    func installerExitWaiterCountForTesting() async -> Int {
        guard let exitLatch else { return 0 }
        return await exitLatch.registeredWaiterCount()
    }

    // MARK: - Private

    /// Finalize an installer handle: discard the process, clear activeHandle,
    /// and call ``handleInstallerExit`` unless this was an intentional stop (in
    /// which case the state machine transition is handled by ``stopAndClean``).
    private func finalizeInstallerHandle(
        handle: SupervisedProcessHandle,
        outcome: ProcessWaitOutcome,
        intentionalStop: Bool
    ) async throws {
        guard finalizedHandleTokens.insert(handle.token).inserted else { return }
        await processSupervisor.discard(handle)
        activeHandle = nil
        if !intentionalStop {
            await handleInstallerExit(outcome: outcome)
        }
    }

    private func handleInstallerExit(outcome: ProcessWaitOutcome) async {
        // If stop was requested, save the exit event and return without
        // transitioning — stopAndClean handles cleanup via finalizeInstallerHandle.
        if stopRequested { return }

        guard var op = currentOperation else { return }
        let exitCode: Int32
        if case .exited(let code) = outcome { exitCode = code } else { exitCode = -1 }

        do {
            if exitCode == 0 {
                try op.transition(to: .installerExited)
                try op.transition(to: .verifyingInstallation)
            } else {
                op.lastError = "Installer exited with code \(exitCode)"
                try setPhase(&op, .failed)
            }
            op.updatedAt = Date()
            self.currentOperation = op
        } catch {
            op.lastError = error.localizedDescription
            self.currentOperation = op
        }
    }

    /// Set phase using transition(to:) as the only mutation path.
    /// On invalid transition, throws.
    private func setPhase(_ op: inout InstallerOperation, _ newPhase: InstallerPhase) throws {
        try op.transition(to: newPhase)
        op.updatedAt = Date()
    }

    /// Mark the current operation as requiring cleanup, recording the reason.
    /// Idempotent: if the operation is already in .cleanupRequired, skips the
    /// transition but still records the error message.
    private func markCleanupRequired(_ reason: String) throws {
        guard var op = currentOperation else {
            throw InstallerError.terminationFailed(reason)
        }
        op.lastError = reason
        if op.phase != .cleanupRequired {
            do {
                try op.transition(to: .cleanupRequired)
            } catch {
                currentOperation = op
                throw error
            }
        }
        currentOperation = op
    }

    /// Clear ALL state atomically — only called when cleanup is fully successful.
    private func stateClear() {
        currentOperation = nil
        activeRuntimeURL = nil
        activePrefixURL = nil
        activeHandle = nil
        installExitTask = nil
        exitLatch = nil
        stopRequested = false
    }

    private func buildBaseEnv(prefixURL: URL, runtimeURL: URL) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefixURL.path,
            "WINEARCH": "win64",
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
        ]
        if let depLayout = RuntimeDependencyLayout(runtimePath: runtimeURL.path) {
            let libDir = depLayout.libDirectory()
            if FileManager.default.fileExists(atPath: libDir.path) {
                env["DYLD_LIBRARY_PATH"] = libDir.path
            }
        }
        return env
    }
}

// MARK: - InstallerExitLatch

/// Broadcast latch that records a process exit outcome and provides
/// a timeout-capable waiter. Multiple callers can wait concurrently.
actor InstallerExitLatch {
    enum State: Sendable {
        case waiting
        case exited(ProcessWaitOutcome)
    }

    private var state: State = .waiting
    private struct Waiter: Sendable {
        let continuation: CheckedContinuation<ProcessWaitOutcome?, Never>
        let deadlineToken: UUID?
        let work: (any CancellableWork)?
    }
    private var waiters: [UUID: Waiter] = [:]
    private let scheduler: any DeadlineScheduling

    init(scheduler: any DeadlineScheduling = DispatchDeadlineScheduler()) {
        self.scheduler = scheduler
    }

    /// Number of registered waiters (for test observability).
    func registeredWaiterCount() -> Int {
        waiters.keys.count
    }

    /// Record an exit outcome, resuming all waiters.
    /// Idempotent: only the first call has effect.
    func record(_ outcome: ProcessWaitOutcome) {
        switch state {
        case .waiting:
            state = .exited(outcome)
            for (_, w) in waiters {
                w.work?.cancel()
                w.continuation.resume(returning: outcome)
            }
            waiters = [:]
        case .exited:
            break // already recorded
        }
    }

    /// Wait indefinitely for the exit outcome.
    func wait() async -> ProcessWaitOutcome {
        if case .exited(let o) = state { return o }
        return await withCheckedContinuation { (c: CheckedContinuation<ProcessWaitOutcome?, Never>) in
            if case .exited(let o) = state { c.resume(returning: o); return }
            let id = UUID()
            waiters[id] = Waiter(continuation: c, deadlineToken: nil, work: nil)
        }!
    }

    /// Wait with a timeout. Returns nil when the deadline fires first.
    func wait(timeout: TimeInterval) async -> ProcessWaitOutcome? {
        if case .exited(let o) = state { return o }

        let id = UUID()
        let token = UUID()
        let work = scheduler.schedule(after: timeout) { [weak self] in
            guard let self else { return }
            Task { await self._deadlineReached(waiterID: id, token: token) }
        }

        return await withCheckedContinuation { c in
            if case .exited(let o) = state {
                work.cancel()
                c.resume(returning: o)
                return
            }
            waiters[id] = Waiter(continuation: c, deadlineToken: token, work: work)
        }
    }

    private func _deadlineReached(waiterID: UUID, token: UUID) {
        guard let w = waiters[waiterID], w.deadlineToken == token else { return }
        waiters.removeValue(forKey: waiterID)
        w.continuation.resume(returning: nil)
    }

    #if DEBUG
    func pendingDeadlineCount() -> Int {
        waiters.values.filter { $0.deadlineToken != nil }.count
    }
    #endif
}

// MARK: - ProcessSupervising

/// Injectable protocol for process lifecycle management, allowing
/// ``InstallerSupervisor`` to accept any supervisor implementation.
protocol ProcessSupervising: Sendable {
    func launch(plan: LaunchPlan, outputPolicy: ProcessOutputPolicy) async throws -> SupervisedProcessHandle
    func requestTerminate(_ handle: SupervisedProcessHandle) async
    func requestForceKill(_ handle: SupervisedProcessHandle) async throws
    func waitForTermination(_ handle: SupervisedProcessHandle) async -> ProcessWaitOutcome
    func discard(_ handle: SupervisedProcessHandle) async
}

extension ProcessSupervisor: ProcessSupervising {}

// MARK: - InstallerLifecycleSupervising

/// Injectable protocol for installer lifecycle management, allowing
/// ``InstallerSupervisor`` to expose installation lifecycle operations.
protocol InstallerLifecycleSupervising: Sendable {
    func snapshot() async -> InstallerOperation?
    func stopAndClean() async throws
    func stopKnownPrefixProcesses(
        wineExecutable: URL,
        wineserverURL: URL,
        prefixURL: URL,
        runtimeURL: URL
    ) async throws
}

extension InstallerSupervisor: InstallerLifecycleSupervising {}
