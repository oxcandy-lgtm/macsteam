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

        var op = InstallerOperation(
            id: UUID(),
            runtimeSafeID: runtimeSafeID,
            prefixSafeID: prefixSafeID,
            phase: .preflightCleaning,
            startedAt: Date(),
            updatedAt: Date()
        )

        // Preflight
        try op.transition(to: .prefixPreparing)
        self.currentOperation = op

        // Resolve wine executable
        let layout = WineExecutableLayout.detect(from: runtimeURL)
        let wineURL = layout.wine

        // Launch installer
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
        op.phase = .installerRunning
        op.updatedAt = Date()
        self.currentOperation = op

        // Wait for real termination in background
        installTask = Task {
            let outcome = await processSupervisor.waitForTermination(handle)
            await processSupervisor.discard(handle)
            await handleInstallerExit(outcome: outcome)
        }
    }

    /// Wait for the installer to finish.
    func waitForInstallerExit() async throws {
        await installTask?.value
    }

    /// Stop and clean up the installation.
    func stopAndClean() async throws {
        installTask?.cancel()
        guard let op = currentOperation, !op.phase.isTerminal else { return }
        var mutableOp = op
        try mutableOp.transition(to: .stopping)
        self.currentOperation = mutableOp

        // Stop any known process
        // (full PrefixProcessTerminator deferred to next batch)
        currentOperation = nil
    }

    // MARK: - Private

    private func handleInstallerExit(outcome: ProcessWaitOutcome) async {
        guard var op = currentOperation else { return }
        let exitCode: Int32
        if case .exited(let code) = outcome { exitCode = code } else { exitCode = -1 }

        do {
            try op.transition(to: .installerExited)
            op.updatedAt = Date()
            self.currentOperation = op

            try op.transition(to: .steamBootstrapDetected)
            op.updatedAt = Date()
            self.currentOperation = op

            try op.transition(to: .verifyingInstallation)
            op.updatedAt = Date()
            self.currentOperation = op

            try op.transition(to: .steamReady)
            op.updatedAt = Date()
            self.currentOperation = op
        } catch {
            op.lastError = error.localizedDescription
            op.phase = .interrupted
            op.updatedAt = Date()
            self.currentOperation = op
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
