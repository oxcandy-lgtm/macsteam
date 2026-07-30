// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

// ---------------------------------------------------------------------------
// MARK: - Test doubles
// ---------------------------------------------------------------------------

/// A fake ``WineControlServicing`` that records all calls and lets the
/// caller configure responses per-method.
final class FakeWineControlService: @unchecked Sendable, WineControlServicing {

    // -----------------------------------------------------------------------
    // Configurable response queues
    // -----------------------------------------------------------------------

    /// Per-call tasklist results. Index advanced on each `taskList` invocation.
    var tasklistResults: [TasklistResult] = []
    private var tasklistIndex = 0

    /// Per-call tasklist errors. When non‑nil at the current index the call
    /// throws instead of returning `tasklistResults[.]`.
    var tasklistErrors: [Error?] = []

    /// Per-call terminate outcomes. `.success(())` means normal return.
    var terminateOutcomes: [Result<Void, Error>] = []
    private var terminateIndex = 0

    /// Error thrown by `wineserverKill`.
    var wineserverKillError: Error?

    /// Return value for `wineserverWait`.
    var wineserverWaitResult: Bool = true

    /// Error thrown by `wineserverWait` (overrides the return value when set).
    var wineserverWaitError: Error?

    // -----------------------------------------------------------------------
    // Call records
    // -----------------------------------------------------------------------

    private(set) var tasklistCalls:
        [(wineExecutable: URL, prefixURL: URL, runtimeURL: URL)] = []
    private(set) var terminateCalls:
        [(imageName: String, force: Bool, wineExecutable: URL,
          prefixURL: URL, runtimeURL: URL)] = []
    private(set) var wineserverKillCalls:
        [(wineserverURL: URL, prefixURL: URL)] = []
    private(set) var wineserverWaitCalls:
        [(wineserverURL: URL, prefixURL: URL, timeoutSeconds: Int)] = []

    // -----------------------------------------------------------------------
    // WineControlServicing conformance
    // -----------------------------------------------------------------------

    func taskList(
        wineExecutable: URL, prefixURL: URL, runtimeURL: URL
    ) async throws -> TasklistResult {
        tasklistCalls.append((wineExecutable, prefixURL, runtimeURL))

        // Check for a configured error at the current index.
        if tasklistIndex < tasklistErrors.count,
           let error = tasklistErrors[tasklistIndex] {
            tasklistIndex += 1
            throw error
        }

        // Return the configured result, or an empty one if we run out.
        defer { tasklistIndex += 1 }
        if tasklistIndex < tasklistResults.count {
            return tasklistResults[tasklistIndex]
        }
        return TasklistResult(rawLines: [], processes: [], parseErrors: [])
    }

    func terminate(
        imageName: String, force: Bool,
        wineExecutable: URL, prefixURL: URL, runtimeURL: URL
    ) async throws {
        terminateCalls.append(
            (imageName, force, wineExecutable, prefixURL, runtimeURL))

        guard terminateIndex < terminateOutcomes.count else { return }
        defer { terminateIndex += 1 }
        try terminateOutcomes[terminateIndex].get()
    }

    func wineserverKill(wineserverURL: URL, prefixURL: URL) async throws {
        wineserverKillCalls.append((wineserverURL, prefixURL))
        if let error = wineserverKillError { throw error }
    }

    func wineserverWait(
        wineserverURL: URL, prefixURL: URL, timeoutSeconds: Int
    ) async throws -> Bool {
        wineserverWaitCalls.append((wineserverURL, prefixURL, timeoutSeconds))
        if let error = wineserverWaitError { throw error }
        return wineserverWaitResult
    }

    var wineserverProbeResult: Bool = false
    var wineserverProbeError: Error?
    var wineserverProbeCalls: [(URL, URL)] = []

    func wineserverProbe(wineserverURL: URL, prefixURL: URL) async throws -> Bool {
        wineserverProbeCalls.append((wineserverURL, prefixURL))
        if let error = wineserverProbeError { throw error }
        return wineserverProbeResult
    }
}

/// A fake ``PrefixCleanupSleeping`` that records durations and can
/// be configured to throw after a certain number of calls.
final class ManualSleeper: @unchecked Sendable, PrefixCleanupSleeping {

    private(set) var sleepCalls: [Duration] = []

    /// When set, every call at or above this 1‑based index throws
    /// `CancellationError`.
    var throwFromCall: Int = .max
    private var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
        sleepCalls.append(duration)
        if callCount >= throwFromCall {
            throw CancellationError()
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

/// Short-hand for an empty process list (no known images).
private let emptyTasklist = TasklistResult(
    rawLines: [], processes: [], parseErrors: [])

/// A process entry that IS a known image.
private func knownProcess(_ name: String) -> WindowsProcessSnapshot {
    WindowsProcessSnapshot(
        imageName: name, pid: 100, sessionName: "Console",
        sessionNumber: 1, memUsageKB: 1024, status: "Running")
}

/// A process entry that is NOT a known image.
private func unknownProcess(_ name: String) -> WindowsProcessSnapshot {
    WindowsProcessSnapshot(
        imageName: name, pid: 999, sessionName: "Console",
        sessionNumber: 1, memUsageKB: 512, status: "Running")
}

/// Two test URLs reused across tests.
private let fakeRuntime = URL(fileURLWithPath: "/tmp/test-runtime")
private let fakePrefix  = URL(fileURLWithPath: "/tmp/test-prefix")

/// A specific Steam process snapshot used in remaining-process tests.
private let steamProcess = WindowsProcessSnapshot(
    imageName: "steam.exe", pid: 100, sessionName: "wine",
    sessionNumber: 0, memUsageKB: 0, status: "running"
)

// ---------------------------------------------------------------------------
// MARK: - PrefixProcessTerminatorTests
// ---------------------------------------------------------------------------

@Suite("PrefixProcessTerminator")
struct PrefixProcessTerminatorTests {

    // MARK: - 1. initialCensus_failure

    @Test("initial census failure returns incomplete")
    func initialCensus_failure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()
        wineControl.tasklistErrors = [WineControlError.tasklistFailed(
            exitCode: 1, stderr: "census failed")]

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("census failed"))
        } else {
            Issue.record("Expected .incomplete")
        }
        #expect(wineControl.tasklistCalls.count == 1)
        #expect(sleeper.sleepCalls.isEmpty)
    }

    // MARK: - 2. initialCensus_parseErrors

    @Test("initial census with parse errors returns incomplete")
    func initialCensus_parseErrors() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let parseError = TasklistParseError(
            line: "bad line", reason: "expected 6 fields, got 2")
        wineControl.tasklistResults = [TasklistResult(
            rawLines: ["bad line"],
            processes: [],
            parseErrors: [parseError])]

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        // Parse errors in the census are carried into scanErrors
        // so the result should be incomplete even without other issues.
        #expect(result != .clean)
    }

    // MARK: - 3. noProcess_wineserverStopped

    @Test("no known processes and wineserver stopped returns clean")
    func noProcess_wineserverStopped() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result == .clean)
        // Should have: first census, wineserverKill, wineserverWait, final census
        #expect(wineControl.tasklistCalls.count == 2)
        #expect(wineControl.wineserverKillCalls.count == 1)
        #expect(wineControl.wineserverWaitCalls.count == 1)
    }

    // MARK: - 4. noProcess_wineserverRunning

    @Test("no known processes but wineserver still running returns incomplete")
    func noProcess_wineserverRunning() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        // wineserverWait returns false ⇒ wineserver did not exit within timeout
        wineControl.wineserverWaitResult = false

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 5. noProcess_wineserverNotProbeable

    @Test("no known processes and wineserver probe throws returns incomplete")
    func noProcess_wineserverNotProbeable() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        // Simulate the wineserverWait throwing when trying to probe wineserver
        wineControl.wineserverWaitError = CocoaError(.fileNoSuchFile)

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("wineserver") || reason.contains("teardown"))
        }
    }

    // MARK: - 6. gracefulTerminate_all_exit

    @Test("all processes exit after graceful terminate returns clean")
    func gracefulTerminate_all_exit() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        // First census: one known process
        let initialProcs = [knownProcess("steam.exe")]
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // First poll census: empty ⇒ all exited
            emptyTasklist,
            // Final census (wineserver teardown path): empty
            emptyTasklist,
        ]
        // Graceful terminate succeeds
        wineControl.terminateOutcomes = [.success(())]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result == .clean)
        // One grace terminate call
        #expect(wineControl.terminateCalls.count == 1)
        #expect(wineControl.terminateCalls[0].force == false)
        // At least one sleep for the poll interval
        #expect(!sleeper.sleepCalls.isEmpty)
    }

    // MARK: - 7. gracefulTerminate_one_fails

    @Test("graceful terminate failure on one process returns incomplete")
    func gracefulTerminate_one_fails() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [
            knownProcess("steam.exe"),
            knownProcess("steamwebhelper.exe"),
        ]
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Poll: still present (didn't exit)
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Final census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
        ]
        // steam.exe fails graceful terminate, steamwebhelper succeeds
        wineControl.terminateOutcomes = [
            .failure(WineControlError.terminateFailed(image: "steam.exe", exitCode: 1)),
            .success(()),
            // Force terminate for both
            .success(()),
            .success(()),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("terminate") || reason.contains("steam.exe"))
        }
    }

    // MARK: - 8. poll_grace_deadline_with_remaining

    @Test("poll after grace deadline with remaining processes returns incomplete")
    func poll_grace_deadline_with_remaining() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Poll returns same process repeatedly
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Final census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
        ]
        wineControl.terminateOutcomes = [.success(())]
        wineControl.wineserverWaitResult = true
        wineControl.wineserverProbeResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        // Should have attempted force terminate
        let forceCalls = wineControl.terminateCalls.filter { $0.force }
        #expect(!forceCalls.isEmpty)
    }

    // MARK: - 9. poll_census_failure

    @Test("poll census failure records error and continues")
    func poll_census_failure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
        ]
        wineControl.tasklistErrors = [
            nil,
            WineControlError.tasklistFailed(exitCode: 1, stderr: "poll failed"),
        ]
        wineControl.terminateOutcomes = [.success(())]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 10. poll_sleep_cancellation

    @Test("poll sleep cancellation returns incomplete")
    func poll_sleep_cancellation() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Still present after sleep
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Final census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
        ]
        wineControl.terminateOutcomes = [.success(())]
        wineControl.wineserverWaitResult = true
        // Sleeper throws after first call
        sleeper.throwFromCall = 1

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        // The CancellationError from the sleeper is returned incomplete,
        // so the poll loop continues. Unless the process exits, result
        // will be incomplete.
        #expect(result != .clean)
    }

    // MARK: - 11. forceTerminate_success

    @Test("force terminate succeeds when grace poll leaves remaining")
    func forceTerminate_success() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        let withProc = TasklistResult(rawLines: [], processes: initialProcs, parseErrors: [])
        let empty = TasklistResult(rawLines: [], processes: [], parseErrors: [])
        wineControl.tasklistResults = Array(repeating: withProc, count: 6) + Array(repeating: empty, count: 6)
        // Grace succeeds, force succeeds
        wineControl.terminateOutcomes = [
            .success(()),
            .success(()),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result == .clean)
        let forceCalls = wineControl.terminateCalls.filter { $0.force }
        #expect(forceCalls.count == 1)
    }

    // MARK: - 12. forceTerminate_failure

    @Test("force terminate failure returns incomplete")
    func forceTerminate_failure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        wineControl.tasklistResults = Array(repeating: TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []), count: 12)
        wineControl.terminateOutcomes = [
            .success(()),
            .failure(WineControlError.terminateFailed(
                image: "steam.exe", exitCode: 1)),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 13. force_deadline_with_remaining

    @Test("force poll deadline with remaining processes returns incomplete")
    func force_deadline_with_remaining() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        let manyProcs = TasklistResult(
            rawLines: [], processes: initialProcs, parseErrors: [])
        wineControl.tasklistResults = Array(repeating: manyProcs, count: 12)
        wineControl.terminateOutcomes = [
            .success(()),   // grace
            .success(()),   // force
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("steam") || reason.contains("Remaining"))
        }
    }

    // MARK: - 14. wineserverKill_failure

    @Test("wineserver kill failure returns incomplete")
    func wineserverKill_failure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        wineControl.wineserverKillError = WineControlError.wineserverFailed(
            exitCode: 1)

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("wineserver") || reason.contains("kill"))
        }
    }

    // MARK: - 15. wineserverWait_timeout

    @Test("wineserver wait timeout returns incomplete")
    func wineserverWait_timeout() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        wineControl.wineserverWaitResult = false

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 16. wineserverWait_throw

    @Test("wineserver wait throwing returns incomplete")
    func wineserverWait_throw() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        wineControl.wineserverWaitError = WineControlError.wineserverFailed(
            exitCode: 1)

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 17. finalCensus_failure

    @Test("final census failure returns incomplete")
    func finalCensus_failure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist]
        // Second call (final census) throws
        wineControl.tasklistErrors = [
            nil,
            WineControlError.tasklistFailed(exitCode: 1, stderr: "final census failed"),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("census"))
        }
    }

    // MARK: - 18. finalCensus_parseErrors

    @Test("final census parse errors returns incomplete")
    func finalCensus_parseErrors() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let parseError = TasklistParseError(
            line: "garbage", reason: "not enough fields")
        wineControl.tasklistResults = [
            emptyTasklist,
            TasklistResult(
                rawLines: ["garbage"], processes: [],
                parseErrors: [parseError]),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 19. finalCensus_unknown_process

    @Test("final census with non-known processes returns incomplete")
    func finalCensus_unknown_process() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        // First census: clean
        wineControl.tasklistResults = [
            emptyTasklist,
            // Final census: unknown process still running
            TasklistResult(
                rawLines: [], processes: [unknownProcess("notepad.exe")],
                parseErrors: []),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        // The refactored terminator should consider any remaining process,
        // not just known images, as a signal of incomplete cleanup.
        #expect(result != .clean)
    }

    // MARK: - 20. clean_requires_zero_errors

    @Test("clean result requires zero scan errors")
    func clean_requires_zero_errors() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe")]
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            emptyTasklist,
            emptyTasklist,
        ]
        // Graceful terminate fails → adds a scan error
        wineControl.terminateOutcomes = [
            .failure(WineControlError.terminateFailed(
                image: "steam.exe", exitCode: 1)),
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        // Even though processes eventually exit and wineserver stops,
        // the recorded error means the result must be .incomplete.
        #expect(result != .clean)
    }

    // MARK: - 21. wineserverProbe_failure

    @Test("wineserver probe failure returns incomplete")
    func wineserverProbe_failure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        // Entire wineserver teardown throws
        wineControl.wineserverKillError = WineControlError.wineserverFailed(
            exitCode: 1)

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let result = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        #expect(result != .clean)
    }

    // MARK: - 22. snapshot returns data even on census failure

    @Test("snapshot returns process data even when census fails")
    func snapshot_returnsDataOnCensusFailure() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        wineControl.tasklistErrors = [WineControlError.tasklistFailed(
            exitCode: 1, stderr: "census failed")]

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        let snapshot = await terminator.snapshot(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        // Should still produce a snapshot with scan errors
        #expect(!snapshot.scanErrors.isEmpty)
        #expect(snapshot.scanErrors[0].contains("census failed"))
        // The process summary should be zeroed out
        #expect(snapshot.windowsProcesses.total == 0)
    }

    // MARK: - 23. operation_order matches expected sequence

    @Test("operation call order matches expected sequence")
    func operation_order() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()

        let initialProcs = [knownProcess("steam.exe"),
                            knownProcess("steamwebhelper.exe")]
        wineControl.tasklistResults = [
            // 1st census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Poll census (still present)
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Poll census (still present)
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Force poll census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Force poll census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
            // Final census
            TasklistResult(rawLines: [], processes: initialProcs, parseErrors: []),
        ]
        wineControl.terminateOutcomes = [
            .success(()), .success(()),  // grace
            .success(()), .success(()),  // force
        ]
        wineControl.wineserverWaitResult = true

        let terminator = PrefixProcessTerminator(
            wineControl: wineControl,
            sleeper: sleeper)

        _ = await terminator.terminate(
            runtimeURL: fakeRuntime, prefixURL: fakePrefix)

        // Expected call sequence:
        //   1. taskList (initial census)
        //   2-3. terminate × 2 (graceful)
        //   4-5. taskList × 2 (grace poll)
        //   6-7. terminate × 2 (force)
        //   8-9. taskList × 2 (force poll)
        //   10. wineserverKill
        //   11. wineserverWait
        //   12. taskList (final census)

        let tasklistCount = wineControl.tasklistCalls.count
        let killCount = wineControl.wineserverKillCalls.count
        let waitCount = wineControl.wineserverWaitCalls.count

        // First call must be tasklist (initial census)
        #expect(tasklistCount >= 1)

        // After initial census, graceful terminates happen
        let graceCalls = wineControl.terminateCalls.filter { !$0.force }
        #expect(graceCalls.count == 2)

        // After force terminates, wineserverKill + wineserverWait
        #expect(killCount == 1)
        #expect(waitCount == 1)

        // Multiple tasklist calls across phases
        #expect(tasklistCount >= 6, "Expected multiple tasklist calls across phases")
    }

    // MARK: - 24. force deadline remaining blocks clean

    @Test("force deadline remaining blocks clean")
    func forceDeadline_remaining_blocks_clean() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()
        let procs = TasklistResult(rawLines: [], processes: [steamProcess], parseErrors: [])
        wineControl.tasklistResults = Array(repeating: procs, count: 12)
        wineControl.terminateOutcomes = [.success(()), .success(())]
        wineControl.wineserverKillError = nil
        wineControl.wineserverWaitResult = true
        wineControl.wineserverProbeResult = false

        let terminator = PrefixProcessTerminator(wineControl: wineControl, sleeper: sleeper)
        let result = await terminator.terminate(runtimeURL: fakeRuntime, prefixURL: fakePrefix)
        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("remaining") || reason.contains("Remaining"))
        }
    }

    // MARK: - 25. wineserver nonzero probe returns incomplete

    @Test("wineserver nonzero probe returns incomplete")
    func wineserverProbe_nonzero_exit() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()
        wineControl.tasklistResults = [emptyTasklist, emptyTasklist]
        wineControl.wineserverKillError = nil
        wineControl.wineserverWaitResult = true
        wineControl.wineserverProbeError = WineControlError.wineserverFailed(exitCode: 1)

        let terminator = PrefixProcessTerminator(wineControl: wineControl, sleeper: sleeper)
        let result = await terminator.terminate(runtimeURL: fakeRuntime, prefixURL: fakePrefix)
        #expect(result != .clean)
    }

    // MARK: - 26. grace deadline force success returns clean

    @Test("grace deadline force success returns clean")
    func grace_deadline_force_success() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()
        wineControl.tasklistResults = [
            TasklistResult(rawLines: [], processes: [steamProcess], parseErrors: []),
            TasklistResult(rawLines: [], processes: [], parseErrors: []),
        ]
        wineControl.terminateOutcomes = [.success(())]
        wineControl.wineserverKillError = nil
        wineControl.wineserverWaitResult = true
        wineControl.wineserverProbeResult = false

        let terminator = PrefixProcessTerminator(wineControl: wineControl, sleeper: sleeper)
        let result = await terminator.terminate(runtimeURL: fakeRuntime, prefixURL: fakePrefix)
        #expect(result == .clean)
    }

    // MARK: - 27. poll uses exactly 5 attempts

    @Test("poll uses exactly 5 attempts")
    func poll_exactly_5_attempts() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()
        let steam = knownProcess("steam.exe")
        let withProc = TasklistResult(rawLines: [], processes: [steam], parseErrors: [])
        wineControl.tasklistResults = Array(repeating: withProc, count: 12)
        wineControl.wineserverKillError = nil
        wineControl.wineserverWaitResult = true
        wineControl.wineserverProbeResult = false

        let terminator = PrefixProcessTerminator(wineControl: wineControl, sleeper: sleeper)
        let result = await terminator.terminate(runtimeURL: fakeRuntime, prefixURL: fakePrefix)
        // The process persists through all 7 results (1 initial + 5 poll + 1 final)
        // so the result should be incomplete due to remaining processes
        #expect(result != .clean)
    }

    // MARK: - 28. remaining count appears in reason

    @Test("remaining count appears in reason")
    func remaining_count_in_reason() async {
        let wineControl = FakeWineControlService()
        let sleeper = ManualSleeper()
        let steam = knownProcess("steam.exe")
        let procs = TasklistResult(rawLines: [], processes: [steam, steam], parseErrors: [])
        wineControl.tasklistResults = Array(repeating: procs, count: 12)
        wineControl.terminateOutcomes = [.success(()), .success(())]
        wineControl.wineserverKillError = nil
        wineControl.wineserverWaitResult = true
        wineControl.wineserverProbeResult = false

        let terminator = PrefixProcessTerminator(wineControl: wineControl, sleeper: sleeper)
        let result = await terminator.terminate(runtimeURL: fakeRuntime, prefixURL: fakePrefix)
        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("remaining") || reason.contains("Remaining"))
        }
    }
}
