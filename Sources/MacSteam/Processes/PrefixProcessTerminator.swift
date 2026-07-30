// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Protocols and outcome types
// ---------------------------------------------------------------------------

/// Public interface for terminating processes inside a Wine prefix.
protocol PrefixProcessTerminating: Sendable {
    func terminate(runtimeURL: URL, prefixURL: URL) async -> PrefixCleanupResult
}
extension PrefixProcessTerminator: PrefixProcessTerminating {}

/// The outcome of a single poll-for-exit loop.
enum PrefixPollOutcome: Sendable, Equatable {
    /// All tracked processes exited before the deadline.
    case exited
    /// The deadline was reached with some processes still running.
    case deadline(remaining: Set<String>)
    /// An error occurred during polling.
    case failed(reason: String)
}

/// Injectable sleep primitive so polling can be controlled in tests.
protocol PrefixCleanupSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

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
// MARK: - DefaultSleeper
// ---------------------------------------------------------------------------

private struct DefaultSleeper: PrefixCleanupSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
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
///    wineserver is stopped, **all** processes are gone, no scan errors,
///    and no parse errors were recorded.
actor PrefixProcessTerminator {

    // MARK: - Constants

    private static let pollAttempts = 5
    private static let pollInterval: Duration = .seconds(1)

    // MARK: - Dependencies

    private let wineControl: any WineControlServicing
    private let processSupervisor: ProcessSupervisor
    private let sleeper: any PrefixCleanupSleeping

    // MARK: - State

    /// Accumulated count of CSV parse errors across all censuses (initial,
    /// poll iterations, final).  Any non-zero count prevents a ``.clean``
    /// result.
    private var censusParseErrors: Int = 0

    init(
        wineControl: any WineControlServicing = WineControlLane(),
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        sleeper: any PrefixCleanupSleeping = DefaultSleeper()
    ) {
        self.wineControl = wineControl
        self.processSupervisor = processSupervisor
        self.sleeper = sleeper
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
    ///   wineserver were stopped without errors, no unknown processes remain,
    ///   and no census parse errors were encountered.
    func terminate(runtimeURL: URL, prefixURL: URL) async -> PrefixCleanupResult {
        let layout = WineExecutableLayout.detect(from: runtimeURL)
        let wineURL = layout.wine
        let wineserverURL = layout.wineserver
        var scanErrors: [String] = []
        censusParseErrors = 0

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

        censusParseErrors += initialCensus.parseErrors.count

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
                remaining: remaining,
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
        switch await pollForExit(
            wineURL: wineURL,
            prefixURL: prefixURL,
            runtimeURL: runtimeURL,
            remaining: remaining,
            duration: .seconds(5)
        ) {
        case .exited:
            remaining = []
        case .deadline(let rem):
            remaining = rem
        case .failed(let reason):
            scanErrors.append("Poll after graceful kill failed: \(reason)")
            // fail-closed: assume nothing exited; proceed to force kill
        }

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
        switch await pollForExit(
            wineURL: wineURL,
            prefixURL: prefixURL,
            runtimeURL: runtimeURL,
            remaining: remaining,
            duration: .seconds(5)
        ) {
        case .exited:
            remaining = []
        case .deadline(let rem):
            remaining = rem
        case .failed(let reason):
            scanErrors.append("Poll after force kill failed: \(reason)")
        }

        // ---------------------------------------------------------------
        // Step 6, 7, 8 – wineserver teardown, final census, result
        // ---------------------------------------------------------------
        return await finishWithWineserverTeardown(
            wineserverURL: wineserverURL,
            prefixURL: prefixURL,
            runtimeURL: runtimeURL,
            wineURL: wineURL,
            remaining: remaining,
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
            let wineserverRunning: Bool
            do {
                wineserverRunning = try await isWineserverRunning(
                    wineserverURL: wineserverURL,
                    prefixURL: prefixURL
                )
            } catch {
                scanErrors.append("wineserver check failed: \(error.localizedDescription)")
                wineserverRunning = true
            }
            return PrefixProcessSnapshot(
                windowsProcesses: summary,
                wineserverRunning: wineserverRunning,
                scanErrors: scanErrors,
                timestamp: Date()
            )
        }

        let wineserverRunning: Bool
        do {
            wineserverRunning = try await isWineserverRunning(
                wineserverURL: wineserverURL,
                prefixURL: prefixURL
            )
        } catch {
            scanErrors.append("wineserver check failed: \(error.localizedDescription)")
            wineserverRunning = true
        }

        let summary = categorizeProcesses(censusResult.processes)

        return PrefixProcessSnapshot(
            windowsProcesses: summary,
            wineserverRunning: wineserverRunning,
            scanErrors: scanErrors,
            timestamp: Date()
        )
    }

    // MARK: - Private Helpers

    /// Poll `tasklist` at 1 s intervals (up to ``pollAttempts`` attempts) until
    /// no known processes remain.
    ///
    /// - Returns: ``PrefixPollOutcome/exited`` when all known processes have
    ///   vanished; ``PrefixPollOutcome/deadline`` when the maximum number of
    ///   attempts is reached with a (possibly empty) set of survivors;
    ///   ``PrefixPollOutcome/failed`` when any individual census call throws or
    ///   produces parse errors (fail-closed – we treat unreliable data as a
    ///   failure).
    private func pollForExit(
        wineURL: URL,
        prefixURL: URL,
        runtimeURL: URL,
        remaining: Set<String>,
        duration: Duration
    ) async -> PrefixPollOutcome {
        // Note: duration parameter kept for compatibility but poll is attempt-based
        var stillRemaining = remaining

        for _ in 0..<Self.pollAttempts {
            guard !stillRemaining.isEmpty else { return .exited }
            do {
                try await sleeper.sleep(for: Self.pollInterval)
                let current = try await wineControl.taskList(
                    wineExecutable: wineURL,
                    prefixURL: prefixURL,
                    runtimeURL: runtimeURL
                )
                if !current.parseErrors.isEmpty {
                    censusParseErrors += current.parseErrors.count
                    return .failed(reason: "Poll census produced \(current.parseErrors.count) parse error(s)")
                }
                let known = current.processes.filter {
                    KnownProcessImage.allLowercased.contains($0.imageName.lowercased())
                }
                stillRemaining = Set(known.map { $0.imageName.lowercased() })
            } catch {
                return .failed(reason: "Poll census failed: \(error.localizedDescription)")
            }
        }

        if stillRemaining.isEmpty { return .exited }
        return .deadline(remaining: stillRemaining)
    }

    /// Perform the wineserver teardown (step 6), final census (step 7), and
    /// determine the result (step 8).
    ///
    /// ``.clean`` is returned only when:
    /// - No known processes remain in the final census
    /// - **All** processes (not just known ones) are gone
    /// - Wineserver is not running
    /// - No scan errors were recorded
    /// - No census parse errors occurred (initial, poll, or final)
    /// - No processes remain from the poll tracking set
    private func finishWithWineserverTeardown(
        wineserverURL: URL,
        prefixURL: URL,
        runtimeURL: URL,
        wineURL: URL,
        remaining: Set<String>,
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

        censusParseErrors += finalCensus.parseErrors.count

        let finalKnown = finalCensus.processes.filter {
            KnownProcessImage.allLowercased.contains($0.imageName.lowercased())
        }

        let wineserverRunning: Bool
        do {
            wineserverRunning = try await wineControl.wineserverProbe(
                wineserverURL: wineserverURL,
                prefixURL: prefixURL
            )
        } catch {
            errors.append("wineserver check failed: \(error.localizedDescription)")
            wineserverRunning = true
        }

        // Step 8 – clean only when nothing is left and no errors
        if finalKnown.isEmpty,
           !wineserverRunning,
           errors.isEmpty,
           finalCensus.processes.isEmpty,
           censusParseErrors == 0,
           remaining.isEmpty {
            return .clean
        }

        var reasons: [String] = []
        if !finalKnown.isEmpty {
            reasons.append("Remaining known processes: \(finalKnown.count)")
        }
        if !remaining.isEmpty {
            reasons.append("Remaining tracked process images: \(remaining.count)")
        }
        if !finalCensus.processes.isEmpty {
            reasons.append("\(finalCensus.processes.count) process(es) still running")
        }
        if wineserverRunning {
            reasons.append("wineserver still running")
        }
        if !errors.isEmpty {
            reasons.append("Errors: \(errors.joined(separator: "; "))")
        }
        if censusParseErrors > 0 {
            reasons.append("\(censusParseErrors) census parse error(s)")
        }
        return .incomplete(reason: reasons.joined(separator: "; "))
    }

    /// Check whether `wineserver` is running for the given prefix by invoking
    /// `wineserver -p` (which prints the PID when running).
    ///
    /// - Throws: ``ProcessRunner/RunnerError`` or any other error from the
    ///   underlying process invocation.
    private func isWineserverRunning(
        wineserverURL: URL,
        prefixURL: URL
    ) async throws -> Bool {
        try await wineControl.wineserverProbe(
            wineserverURL: wineserverURL,
            prefixURL: prefixURL
        )
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
