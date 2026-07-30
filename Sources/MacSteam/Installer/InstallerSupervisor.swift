// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Single-owner supervisor for Steam installation lifecycle.
///
/// Owns the installer process through ProcessSupervisor directly (not
/// GameSessionSupervisor). Transitions through InstallerPhase via the
/// InstallerOperation state machine. All phase transitions are validated.
///
/// ## Single-wait authority
///
/// The ``installExitTask`` is the **only** task that waits for the installer
/// process to exit. Both the normal-exit path (``waitForInstallerExit()``) and
/// the stop path (``stopAndClean()``) read from this single task, guaranteeing
/// that the exit event is observed exactly once.
actor InstallerSupervisor {
    private let processSupervisor: ProcessSupervisor
    private let prefixTerminator: any PrefixProcessTerminating

    private(set) var currentOperation: InstallerOperation?
    private var installExitTask: Task<ProcessWaitOutcome, Never>?
    private var activeHandle: SupervisedProcessHandle?
    private var activeRuntimeURL: URL?
    private var activePrefixURL: URL?
    private var stopRequested = false
    private var finalizedHandleToken: UUID?

    init(
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
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

            // Single-wait authority: the exit task only waits — cleanup happens
            // in finalizeInstallerHandle called by stopAndClean or waitForInstallerExit.
            installExitTask = Task { [processSupervisor] in
                await processSupervisor.waitForTermination(handle)
            }
        } catch {
            op.lastError = error.localizedDescription
            try? op.transition(to: .interrupted)
            self.currentOperation = op
            throw error
        }
    }

    /// Wait for the installer to finish.
    ///
    /// Blocks until the installer exits naturally, then finalises the handle
    /// and transitions the state machine via ``handleInstallerExit``.
    func waitForInstallerExit() async throws {
        guard let handle = activeHandle, let task = installExitTask else { return }
        let outcome = await task.value
        try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: false)
    }

    /// Stop the installer and clean up. Fail-closed: if the installer process
    /// does not exit after SIGKILL, state is NOT cleared and an error is thrown.
    func stopAndClean() async throws {
        stopRequested = true

        guard let handle = activeHandle else { return }

        // Terminate owned installer process
        await processSupervisor.requestTerminate(handle)

        // Single wait authority — wait for existing exit task
        if let outcome = try? await waitForExitTask(timeout: 5) {
            try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: true)
        } else {
            // Timeout — force kill
            try await processSupervisor.requestForceKill(handle)
            if let outcome = try? await waitForExitTask(timeout: 3) {
                // Exited after SIGKILL
                try await finalizeInstallerHandle(handle: handle, outcome: outcome, intentionalStop: true)
            } else {
                // Still not confirmed — must NOT clear state
                throw InstallerError.terminationFailed("Installer did not exit after SIGKILL")
            }
        }

        // Clean up prefix
        guard let runtimeURL = activeRuntimeURL, let prefixURL = activePrefixURL else { return }
        let result = await prefixTerminator.terminate(runtimeURL: runtimeURL, prefixURL: prefixURL)

        switch result {
        case .clean:
            stateClear()
        case .incomplete(let reason):
            throw InstallerError.terminationFailed("Prefix cleanup incomplete: \(reason)")
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
        defer {
            if finalizedHandleToken == handle.token {
                finalizedHandleToken = nil
            }
        }
        // Guard against double-finalization
        if finalizedHandleToken == handle.token { return }
        finalizedHandleToken = handle.token

        await processSupervisor.discard(handle)
        activeHandle = nil

        if !intentionalStop {
            await handleInstallerExit(outcome: outcome)
        }
    }

    /// Wait for the existing exit task to complete, with a timeout.
    private func waitForExitTask(timeout: TimeInterval) async throws -> ProcessWaitOutcome {
        let task = installExitTask
        guard let task else {
            throw TimeoutError()
        }
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                // Race between exit and timeout
                let timeoutTask = Task {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    continuation.resume(throwing: TimeoutError())
                }
                let outcome = await task.value
                timeoutTask.cancel()
                continuation.resume(returning: outcome)
            }
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
            try? setPhase(&op, .interrupted)
        }
    }

    /// Set phase using transition(to:) as the only mutation path.
    /// On invalid transition, throws.
    private func setPhase(_ op: inout InstallerOperation, _ newPhase: InstallerPhase) throws {
        try op.transition(to: newPhase)
        op.updatedAt = Date()
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

/// Timeout error used internally by ``InstallerSupervisor/waitForExitTask(timeout:)``.
private struct TimeoutError: Error {}
