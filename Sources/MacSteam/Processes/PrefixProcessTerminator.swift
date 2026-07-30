// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Known image names
// ---------------------------------------------------------------------------

/// Process image names that `PrefixProcessTerminator` recognises and can
/// terminate.
private enum KnownProcessImage: String, CaseIterable, Sendable {
    case steamSetup   = "steamsetup.exe"
    case steam        = "steam.exe"
    case steamWebHelpers = "steamwebhelper.exe"
    case steamService = "steamservice.exe"
    case crashHandler = "crashhandler.exe"

    /// All known image names as a lowercased set (fast lookup).
    static let allLowercased: Set<String> = Set(allCases.map { $0.rawValue.lowercased() })
}

// ---------------------------------------------------------------------------
// MARK: - PrefixProcessTerminator
// ---------------------------------------------------------------------------

/// Orchestrates the orderly termination of Windows processes inside a Wine
/// prefix, following this stop order:
///
/// 1. Census via ``WineControlLane``
/// 2. Graceful `taskkill` on known images that exist
/// 3. Poll for 5 s (1 s intervals)
/// 4. Force `taskkill` on remaining
/// 5. Poll for 5 s (1 s intervals)
/// 6. `wineserver -k`, then `wineserver -w`
/// 7. Final census
/// 8. Return ``PrefixCleanupResult/clean`` only when zero known processes,
///    wineserver is stopped, **and** no scan errors were recorded.
actor PrefixProcessTerminator {

    // MARK: - Dependencies

    private let wineControl: WineControlLane
    private let processSupervisor: ProcessSupervisor

    // MARK: - Init

    init(
        wineControl: WineControlLane = WineControlLane(),
        processSupervisor: ProcessSupervisor = ProcessSupervisor()
    ) {
        self.wineControl = wineControl
        self.processSupervisor = processSupervisor
    }

    // MARK: - Terminate

    /// Execute the full stop order for the given Wine prefix.
    ///
    /// - Parameters:
    ///   - runtimeURL: The Wine runtime root (used to resolve `wine` and
    ///     `wineserver` executables via ``WineExecutableLayout``).
    ///   - prefixURL: The ``WINEPREFIX`` directory whose processes should be
    ///     cleaned up.
    /// - Returns: ``PrefixCleanupResult/clean`` iff all known processes and
    ///   wineserver were stopped without errors.
    func terminate(runtimeURL: URL, prefixURL: URL) async -> PrefixCleanupResult {
        let layout = WineExecutableLayout.detect(from: runtimeURL)
        let wineURL = layout.wine
        let wineserverURL = layout.wineserver
        var scanErrors: [String] = []

        // ---------------------------------------------------------------
        // Step 1 – census
        // ---------------------------------------------------------------
        let initialCensus: TasklistResult
        do {
            initialCensus = try await wineControl.taskList(
                wineExecutable: wineURL,
                prefixURL: prefixURL,
                runtimeURL: runtimeURL
            )
        } catch {
            let msg = "Initial census failed: \(error.localizedDescription)"
            scanErrors.append(msg)
            return .incomplete(reason: msg)
        }

        let initialKnown = initialCensus.processes.filter {
            KnownProcessImage.allLowercased.contains($0.imageName.lowercased())
        }
        var remaining = Set(initialKnown.map { $0.imageName.lowercased() })

        // Short-circuit when there are no known processes to kill.
        guard !remaining.isEmpty else {
            return await finishWithWineserverTeardown(
                wineserverURL: wineserverURL,
                prefixURL: prefixURL,
                runtimeURL: runtimeURL,
                wineURL: wineURL,
                scanErrors: scanErrors
            )
        }

        // ---------------------------------------------------------------
        // Step 2 – graceful taskkill
        // ---------------------------------------------------------------
        for image in remaining {
            do {
                try await wineControl.terminate(
                    imageName: image,
                    force: false,
                    wineExecutable: wineURL,
                    prefixURL: prefixURL,
                    runtimeURL: runtimeURL
                )
            } catch {
                scanErrors.append("Graceful kill of \(image) failed: \(error.localizedDescription)")
            }
        }

        // ---------------------------------------------------------------
        // Step 3 – poll 5 s (1 s intervals)
        // ---------------------------------------------------------------
        await pollForExit(
            wineURL: wineURL,
            prefixURL: prefixURL,
            runtimeURL: runtimeURL,
            remaining: &remaining,
            duration: .seconds(5)
        )

        // ---------------------------------------------------------------
        // Step 4 – force taskkill on remaining
        // ---------------------------------------------------------------
        for image in remaining {
            do {
                try await wineControl.terminate(
                    imageName: image,
                    force: true,
                    wineExecutable: wineURL,
                    prefixURL: prefixURL,
                    runtimeURL: runtimeURL
                )
            } catch {
                scanErrors.append("Force kill of \(image) failed: \(error.localizedDescription)")
            }
        }

        // ---------------------------------------------------------------
        // Step 5 – poll 5 s (1 s intervals)
        // ---------------------------------------------------------------
        await pollForExit(
            wineURL: wineURL,
            prefixURL: prefixURL,
            runtimeURL: runtimeURL,
            remaining: &remaining,
            duration: .seconds(5)
        )

        // ---------------------------------------------------------------
        // Step 6 – wineserver teardown
        // ---------------------------------------------------------------
        return await finishWithWineserverTeardown(
            wineserverURL: wineserverURL,
            prefixURL: prefixURL,
            runtimeURL: runtimeURL,
            wineURL: wineURL,
            scanErrors: scanErrors
        )
    }

    // MARK: - Snapshot

    /// Capture a point-in-time snapshot of the Windows process state inside
    /// the given Wine prefix.
    ///
    /// - Parameters:
    ///   - runtimeURL: The Wine runtime root (resolves `wine` and `wineserver`
    ///     executables).
    ///   - prefixURL: The ``WINEPREFIX`` directory to scan.
    /// - Returns: A ``PrefixProcessSnapshot`` with the current process summary,
    ///   wineserver status, and any scan errors encountered.
    func snapshot(runtimeURL: URL, prefixURL: URL) async -> PrefixProcessSnapshot {
        let layout = WineExecutableLayout.detect(from: runtimeURL)
        let wineURL = layout.wine
        let wineserverURL = layout.wineserver

        var scanErrors: [String] = []

        let censusResult: TasklistResult
        do {
            censusResult = try await wineControl.taskList(
                wineExecutable: wineURL,
                prefixURL: prefixURL,
                runtimeURL: runtimeURL
            )
        } catch {
            scanErrors.append("Census failed: \(error.localizedDescription)")
            let summary = PrefixWindowsProcessSummary(
                steamSetup: 0,
                steam: 0,
                steamWebHelpers: 0,
                steamService: 0,
                crashHandler: 0,
                other: 0,
                total: 0
            )
            return PrefixProcessSnapshot(
                windowsProcesses: summary,
                wineserverRunning: await isWineserverRunning(
                    wineserverURL: wineserverURL,
                    prefixURL: prefixURL
                ),
                scanErrors: scanErrors,
                timestamp: Date()
            )
        }

        let wineserverRunning = await isWineserverRunning(
            wineserverURL: wineserverURL,
            prefixURL: prefixURL
        )

        let summary = categorizeProcesses(censusResult.processes)

        return PrefixProcessSnapshot(
            windowsProcesses: summary,
            wineserverRunning: wineserverRunning,
            scanErrors: scanErrors,
            timestamp: Date()
        )
    }

    // MARK: - Private Helpers

    /// Poll `tasklist` at 1 s intervals (up to ``duration`` seconds) until no
    /// known processes remain, updating `remaining` in place.
    private func pollForExit(
        wineURL: URL,
        prefixURL: URL,
        runtimeURL: URL,
        remaining: inout Set<String>,
        duration: Duration
    ) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline, !remaining.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            guard let current = try? await wineControl.taskList(
                wineExecutable: wineURL,
                prefixURL: prefixURL,
                runtimeURL: runtimeURL
            ) else {
                continue
            }
            let known = current.processes.filter {
                KnownProcessImage.allLowercased.contains($0.imageName.lowercased())
            }
            remaining = Set(known.map { $0.imageName.lowercased() })
        }
    }

    /// Perform the wineserver teardown (step 6), final census (step 7), and
    /// determine the result (step 8).
    private func finishWithWineserverTeardown(
        wineserverURL: URL,
        prefixURL: URL,
        runtimeURL: URL,
        wineURL: URL,
        scanErrors: [String]
    ) async -> PrefixCleanupResult {
        var errors = scanErrors

        // Step 6 – wineserver -k, wineserver -w
        do {
            try await wineControl.wineserverKill(
                wineserverURL: wineserverURL,
                prefixURL: prefixURL
            )
            let exited = try await wineControl.wineserverWait(
                wineserverURL: wineserverURL,
                prefixURL: prefixURL,
                timeoutSeconds: 5
            )
            if !exited {
                errors.append("wineserver did not exit within 5 s timeout")
            }
        } catch {
            errors.append("wineserver teardown failed: \(error.localizedDescription)")
        }

        // Step 7 – final census
        let finalCensus: TasklistResult
        do {
            finalCensus = try await wineControl.taskList(
                wineExecutable: wineURL,
                prefixURL: prefixURL,
                runtimeURL: runtimeURL
            )
        } catch {
            errors.append("Final census failed: \(error.localizedDescription)")
            return .incomplete(reason: "Final census failed: \(error.localizedDescription)")
        }

        let finalKnown = finalCensus.processes.filter {
            KnownProcessImage.allLowercased.contains($0.imageName.lowercased())
        }
        let wineserverRunning = await isWineserverRunning(
            wineserverURL: wineserverURL,
            prefixURL: prefixURL
        )

        // Step 8 – clean only if nothing is left and no errors
        if finalKnown.isEmpty, !wineserverRunning, errors.isEmpty {
            return .clean
        }

        var reasons: [String] = []
        if !finalKnown.isEmpty {
            let images = Set(finalKnown.map(\.imageName)).sorted()
            reasons.append("Remaining processes: \(images.joined(separator: ", "))")
        }
        if wineserverRunning {
            reasons.append("wineserver still running")
        }
        if !errors.isEmpty {
            reasons.append("Errors: \(errors.joined(separator: "; "))")
        }
        return .incomplete(reason: reasons.joined(separator: "; "))
    }

    /// Check whether `wineserver` is running for the given prefix by invoking
    /// `wineserver -p` (which prints the PID when running).
    private nonisolated func isWineserverRunning(
        wineserverURL: URL,
        prefixURL: URL
    ) async -> Bool {
        let runner = ProcessRunner()
        let result = try? await runner.run(
            executable: wineserverURL,
            arguments: ["-p"],
            environment: [
                "WINEPREFIX": prefixURL.path,
                "WINEDEBUG": "-all",
            ],
            timeout: 5
        )
        guard let result else { return false }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !output.isEmpty
    }

    /// Categorise a raw process list into a ``PrefixWindowsProcessSummary``.
    private nonisolated func categorizeProcesses(
        _ processes: [WindowsProcessSnapshot]
    ) -> PrefixWindowsProcessSummary {
        var steamSetup = 0
        var steam = 0
        var steamWebHelpers = 0
        var steamService = 0
        var crashHandler = 0
        var other = 0

        for proc in processes {
            switch proc.imageName.lowercased() {
            case KnownProcessImage.steamSetup.rawValue.lowercased():
                steamSetup += 1
            case KnownProcessImage.steam.rawValue.lowercased():
                steam += 1
            case KnownProcessImage.steamWebHelpers.rawValue.lowercased():
                steamWebHelpers += 1
            case KnownProcessImage.steamService.rawValue.lowercased():
                steamService += 1
            case KnownProcessImage.crashHandler.rawValue.lowercased():
                crashHandler += 1
            default:
                other += 1
            }
        }

        let total = steamSetup + steam + steamWebHelpers + steamService + crashHandler + other

        return PrefixWindowsProcessSummary(
            steamSetup: steamSetup,
            steam: steam,
            steamWebHelpers: steamWebHelpers,
            steamService: steamService,
            crashHandler: crashHandler,
            other: other,
            total: total
        )
    }
}
