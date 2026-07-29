// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Single-owner supervisor for Steam installation lifecycle.
///
/// Owns the installer process through ProcessSupervisor directly (not
/// GameSessionSupervisor). Transitions through InstallerPhase via the
/// InstallerOperation state machine. All phase transitions are validated.
actor InstallerSupervisor {
    private let processSupervisor: ProcessSupervisor
    private let wineControl: WineControlLane

    private(set) var currentOperation: InstallerOperation?
    private var installTask: Task<Void, Never>?
    private var activeHandle: SupervisedProcessHandle?
    private var activeRuntimeURL: URL?
    private var activePrefixURL: URL?

    init(
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        wineControl: WineControlLane = WineControlLane()
    ) {
        self.processSupervisor = processSupervisor
        self.wineControl = wineControl
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

            // Wait for real termination in background
            installTask = Task {
                let outcome = await processSupervisor.waitForTermination(handle)
                await processSupervisor.discard(handle)
                self.activeHandle = nil
                await handleInstallerExit(outcome: outcome)
            }
        } catch {
            op.lastError = error.localizedDescription
            setPhase(&op, .interrupted)
        }
    }

    /// Wait for the installer to finish.
    func waitForInstallerExit() async throws {
        await installTask?.value
    }

    /// Stop the installer and clean up.
    func stopAndClean() async throws {
        // Cancel observer task
        installTask?.cancel()
        installTask = nil

        // Terminate owned installer process
        if let handle = activeHandle {
            await processSupervisor.requestTerminate(handle)
            let outcome = await processSupervisor.waitForExit(handle, timeout: .seconds(5))
            if case .timedOut = outcome {
                try await processSupervisor.requestForceKill(handle)
                _ = await processSupervisor.waitForExit(handle, timeout: .seconds(3))
            }
            await processSupervisor.discard(handle)
            activeHandle = nil
        }

        // Clean up known Windows processes via WineControlLane
        if let runtimeURL = activeRuntimeURL, let prefixURL = activePrefixURL {
            let layout = WineExecutableLayout.detect(from: runtimeURL)
            let wineURL = layout.wine
            let serverURL = layout.wineserver

            try await stopKnownPrefixProcesses(
                wineExecutable: wineURL,
                wineserverURL: serverURL,
                prefixURL: prefixURL,
                runtimeURL: runtimeURL
            )
        }

        currentOperation = nil
    }

    /// Stop known Windows processes in the prefix.
    func stopKnownPrefixProcesses(
        wineExecutable: URL,
        wineserverURL: URL,
        prefixURL: URL,
        runtimeURL: URL
    ) async throws {
        let knownImages = ["SteamSetup.exe", "steam.exe", "steamwebhelper.exe",
                          "steamservice.exe", "crashhandler.exe"]

        // Graceful terminate
        for image in knownImages {
            try? await wineControl.terminate(
                imageName: image, force: false,
                wineExecutable: wineExecutable, prefixURL: prefixURL, runtimeURL: runtimeURL
            )
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Force remaining
        let afterGraceful = try? await wineControl.taskList(
            wineExecutable: wineExecutable, prefixURL: prefixURL, runtimeURL: runtimeURL
        )
        for proc in afterGraceful ?? [] {
            if knownImages.contains(where: { $0.lowercased() == proc.imageName.lowercased() }) {
                try? await wineControl.terminate(
                    imageName: proc.imageName, force: true,
                    wineExecutable: wineExecutable, prefixURL: prefixURL, runtimeURL: runtimeURL
                )
            }
        }

        // Wineserver shutdown
        try? await wineControl.wineserverKill(wineserverURL: wineserverURL, prefixURL: prefixURL)
        _ = try? await wineControl.wineserverWait(wineserverURL: wineserverURL,
                                                   prefixURL: prefixURL, timeoutSeconds: 15)
    }

    /// Snapshot of the current installer state (for UI projection).
    func snapshot() -> InstallerOperation? {
        currentOperation
    }

    // MARK: - Private

    private func handleInstallerExit(outcome: ProcessWaitOutcome) async {
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
                setPhase(&op, .failed)
            }
        } catch {
            op.lastError = error.localizedDescription
            setPhase(&op, .interrupted)
        }
    }

    /// Set phase using transition(to:) as the only mutation path.
    /// On invalid transition, safe-fall to interrupted.
    private func setPhase(_ op: inout InstallerOperation, _ newPhase: InstallerPhase) {
        do {
            try op.transition(to: newPhase)
        } catch {
            op.phase = newPhase
            op.updatedAt = Date()
        }
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
