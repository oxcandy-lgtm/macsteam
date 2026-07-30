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
/// The ``exitLatch`` is the **single authority** for observing the installer
/// process's exit. An ``installExitTask`` calls ``InstallerExitLatch/record(_:)``
/// when ``ProcessSupervising/waitForTermination(_:)`` returns. Both the normal-exit
/// path (``waitForInstallerExit()``) and the stop path (``stopAndClean()``) read
/// from the latch, guaranteeing that the exit event is observed exactly once.
actor InstallerSupervisor {
    private let processSupervisor: any ProcessSupervising
    private let prefixTerminator: any PrefixProcessTerminating
    private let exitLatch = InstallerExitLatch()

    private(set) var currentOperation: InstallerOperation?
    private var installExitTask: Task<Void, Never>?
    private var activeHandle: SupervisedProcessHandle?
    private var activeRuntimeURL: URL?
    private var activePrefixURL: URL?
    private var stopRequested = false
    private var finalizedHandleTokens: Set<UUID> = []

    init(
        processSupervisor: any ProcessSupervising = ProcessSupervisor(),
        prefixTerminator: any PrefixProcessTerminating = PrefixProcessTerminator()
    ) {
        self.processSupervisor = processSupervisor
        self.prefixTerminator = prefixTerminator
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
        guard currentOperation == nil || currentOperation?.phase.isTerminal == true else {
            throw InstallerError.terminationFailed("Installer already running")
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

            // Single-wait authority: the exit task records into the latch.
            // Cleanup happens in finalizeInstallerHandle called by stopAndClean
            // or waitForInstallerExit.
            installExitTask = Task { [processSupervisor, exitLatch] in
                let outcome = await processSupervisor.waitForTermination(handle)
                await exitLatch.record(outcome)
            }
        } catch {
            op.lastError = error.localizedDescription
            // Silently fall back if the phase is already terminal
            do { try op.transition(to: .interrupted) } catch {}
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
        guard let handle = activeHandle else { return }
        let outcome = await exitLatch.wait(timeout: Double.infinity)
        if let outcome {
            try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: false)
        }
    }

    /// Stop the installer and clean up. Fail-closed: if the installer process
    /// does not exit after SIGKILL, state is NOT cleared and an error is thrown.
    func stopAndClean() async throws {
        stopRequested = true

        if let handle = activeHandle {
            await processSupervisor.requestTerminate(handle)

            if let outcome = await exitLatch.wait(timeout: 5) {
                try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: true)
            } else {
                // Timeout — force kill
                try await processSupervisor.requestForceKill(handle)
                if let outcome = await exitLatch.wait(timeout: 3) {
                    try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: true)
                } else {
                    try markCleanupRequired("Installer did not exit after SIGKILL")
                    throw InstallerError.terminationFailed("Installer did not exit after SIGKILL")
                }
            }
        }

        // Clean up prefix
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
                op.updatedAt = Date()
                self.currentOperation = op

                // Proceed to verification (bootstrap detection deferred to next batch)
                try op.transition(to: .verifyingInstallation)
                op.updatedAt = Date()
                self.currentOperation = op

                // Note: .steamReady is NOT set here — requires dedicated verification
                // that produces GREEN. The coordinator must explicitly advance.
            } else {
                op.lastError = "Installer exited with code \(exitCode)"
                try setPhase(&op, .failed)
            }
        } catch {
            op.lastError = error.localizedDescription
            do { try setPhase(&op, .interrupted) } catch {}
        }
    }

    /// Set phase using transition(to:) as the only mutation path.
    /// On invalid transition, throws.
    private func setPhase(_ op: inout InstallerOperation, _ newPhase: InstallerPhase) throws {
        try op.transition(to: newPhase)
        op.updatedAt = Date()
    }

    /// Mark the current operation as requiring cleanup, recording the reason.
    private func markCleanupRequired(_ reason: String) throws {
        guard var op = currentOperation else { return }
        op.lastError = reason
        try op.transition(to: .cleanupRequired)
        currentOperation = op
    }

    /// Clear ALL state atomically — only called when cleanup is fully successful.
    private func stateClear() {
        currentOperation = nil
        activeRuntimeURL = nil
        activePrefixURL = nil
        activeHandle = nil
        installExitTask = nil
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

/// Single-consumer latch that records a process exit outcome and provides
/// a timeout-capable waiter.
actor InstallerExitLatch {
    enum State: Sendable {
        case waiting
        case exited(ProcessWaitOutcome)
    }

    private var state: State = .waiting
    private var waiter: CheckedContinuation<ProcessWaitOutcome?, Never>?
    private var deadlineToken: UUID?
    private let scheduler: DeadlineScheduling

    init(scheduler: DeadlineScheduling = DispatchDeadlineScheduler()) {
        self.scheduler = scheduler
    }

    /// Record an exit outcome, resuming any waiter.
    func record(_ outcome: ProcessWaitOutcome) {
        switch state {
        case .waiting:
            state = .exited(outcome)
            waiter?.resume(returning: outcome)
            waiter = nil
        case .exited:
            break // already recorded
        }
    }

    /// Wait for the recorded outcome, with a timeout.
    ///
    /// - Returns: The ``ProcessWaitOutcome`` if recorded before the timeout,
    ///   or `nil` if the deadline was reached first.
    func wait(timeout: TimeInterval) async -> ProcessWaitOutcome? {
        if case .exited(let o) = state { return o }

        let token = UUID()
        deadlineToken = token

        let work = scheduler.schedule(after: timeout) { [weak self] in
            guard let self else { return }
            Task { await self._deadlineReached(token: token) }
        }

        let result = await withCheckedContinuation { (c: CheckedContinuation<ProcessWaitOutcome?, Never>) in
            if case .exited(let o) = state {
                c.resume(returning: o)
                return
            }
            waiter = c
        }

        work.cancel()
        if token == deadlineToken { deadlineToken = nil }
        return result
    }

    private func _deadlineReached(token: UUID) {
        guard token == deadlineToken else { return }
        deadlineToken = nil
        waiter?.resume(returning: nil)
        waiter = nil
    }
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
