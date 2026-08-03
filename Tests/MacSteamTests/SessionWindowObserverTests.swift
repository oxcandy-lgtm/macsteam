// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import CoreGraphics
@testable import MacSteam

private func makeWindow(
    owner: String = "Steam",
    title: String? = nil,
    pid: Int32 = 100,
    layer: Int = 0,
    alpha: Double = 1.0,
    width: Double = 800,
    height: Double = 600
    ) -> WindowInfo {
    WindowInfo(
        ownerPID: pid,
        ownerName: owner,
        windowTitle: title,
        layer: layer,
        alpha: alpha,
        boundsWidth: width,
        boundsHeight: height
    )
}

private func boundsDictionary(width: Double, height: Double) -> [String: Any] {
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    return (CGRectCreateDictionaryRepresentation(rect) as? [String: Any]) ?? [:]
}

private func windowRow(
    pid: Int32 = 123,
    layer: Int = 0,
    alpha: Double = 1.0,
    width: Double = 800,
    height: Double = 600,
    owner: String = "Steam",
    title: String? = "Steam"
    ) -> [String: Any] {
    var row: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowAlpha as String: NSNumber(value: alpha),
        kCGWindowBounds as String: boundsDictionary(width: width, height: height),
        kCGWindowOwnerName as String: owner,
    ]
    if let title {
        row[kCGWindowName as String] = title
    }
    return row
}

final class MockWindowProvider: WindowInfoProviding, @unchecked Sendable {
    var windows: [WindowInfo] = []
    var shouldThrow = false
    private(set) var snapshotCount = 0

    func snapshot() throws -> [WindowInfo] {
        snapshotCount += 1
        if shouldThrow { throw WindowObserverError.snapshotFailed }
        return windows
    }
}

// MARK: - Target derivation

struct WindowTargetTests {
    @Test("steam installer/setup derive Steam")
    func steamDerivation() {
        #expect(WindowTarget.derive(purpose: .steamInstaller, recipeID: "steam-setup") == .steam)
        #expect(WindowTarget.derive(purpose: .steamSetup, recipeID: "steam-setup") == .steam)
    }

    @Test("game with canonical cloverpit recipe derives CloverPit")
    func cloverPitDerivation() {
        #expect(WindowTarget.derive(purpose: .game, recipeID: "cloverpit") == .cloverPit)
    }

    @Test("unknown recipe derives unsupported")
    func unsupportedDerivation() {
        #expect(WindowTarget.derive(purpose: .game, recipeID: "something-else") == .unsupported)
        #expect(WindowTarget.derive(purpose: .game, recipeID: "CloverPit") == .unsupported)
    }
}

// MARK: - Matcher

struct WindowMatcherTests {
    @Test("Steam positive match on owner name")
    func steamPositive() {
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "Steam"), target: .steam))
    }

    @Test("Steam positive match on window title")
    func steamPositiveTitle() {
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "wine", title: "Steam"), target: .steam))
    }

    @Test("CloverPit positive match")
    func cloverPitPositive() {
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "CloverPit"), target: .cloverPit))
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "wine", title: "CloverPit"), target: .cloverPit))
    }

    @Test("case and Unicode normalization")
    func caseAndUnicodeNormalization() {
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "STEAM"), target: .steam))
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "steam"), target: .steam))
        #expect(WindowMatcher.isValidCandidate(makeWindow(owner: "cloverpit"), target: .cloverPit))
        #expect(WindowMatcher.isValidCandidate(makeWindow(title: "\u{00AB}Steam\u{00BB}"), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "\u{00E9}Steam"), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "e\u{0301}Steam"), target: .steam))
    }

    @Test("generic Wine-only identity rejected")
    func genericWineOnlyRejected() {
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "Wine", title: "Wine"), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "wine", title: "wineserver"), target: .cloverPit))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "Wine", title: "Wine"), target: .cloverPit))
    }

    @Test("SteamVR rejected by word boundary")
    func steamVRRejected() {
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "SteamVR"), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "wine", title: "SteamVR Monitor"), target: .steam))
    }

    @Test("CloverPitBackup rejected by word boundary")
    func cloverPitBackupRejected() {
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "CloverPitBackup"), target: .cloverPit))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(title: "CloverPitBackup Tool"), target: .cloverPit))
    }

    @Test("structural filters reject invalid layer/alpha/bounds/pid")
    func structuralRejection() {
        #expect(!WindowMatcher.isValidCandidate(makeWindow(layer: 1), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(alpha: 0), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(alpha: -0.5), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(width: 0), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(height: 0), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(width: -10), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(pid: 0), target: .steam))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(pid: -1), target: .steam))
    }

    @Test("unsupported target never matches")
    func unsupportedNeverMatches() {
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "Steam"), target: .unsupported))
        #expect(!WindowMatcher.isValidCandidate(makeWindow(owner: "CloverPit"), target: .unsupported))
    }

    @Test("multiple windows for same target aggregate to positive")
    func multipleWindowsAggregate() {
        let windows = [
            makeWindow(owner: "Steam", title: "SteamVR"),
            makeWindow(owner: "Steam", title: "Friends"),
            ]
        let hit = windows.contains { WindowMatcher.isValidCandidate($0, target: .steam) }
        #expect(hit)
    }
}

// MARK: - Conversion

struct WindowInfoConversionTests {
    @Test("valid row normalizes into value type")
    func validRow() {
        let info = WindowInfo(normalizing: windowRow(pid: 555, owner: "Steam", title: "Steam Games"))
        let unwrapped = try! #require(info)
        #expect(unwrapped.ownerPID == 555)
        #expect(unwrapped.ownerName == "Steam")
        #expect(unwrapped.windowTitle == "Steam Games")
        #expect(unwrapped.layer == 0)
        #expect(unwrapped.alpha == 1.0)
        #expect(unwrapped.boundsWidth == 800)
        #expect(unwrapped.boundsHeight == 600)
    }

    @Test("malformed rows are ignored")
    func malformedRowsIgnored() {
        var missingPID = windowRow()
        missingPID.removeValue(forKey: kCGWindowOwnerPID as String)
        #expect(WindowInfo(normalizing: missingPID) == nil)

        #expect(WindowInfo(normalizing: windowRow(pid: 0)) == nil)
        #expect(WindowInfo(normalizing: windowRow(pid: -3)) == nil)

        var missingLayer = windowRow()
        missingLayer.removeValue(forKey: kCGWindowLayer as String)
        #expect(WindowInfo(normalizing: missingLayer) == nil)

        var missingAlpha = windowRow()
        missingAlpha.removeValue(forKey: kCGWindowAlpha as String)
        #expect(WindowInfo(normalizing: missingAlpha) == nil)

        var missingBounds = windowRow()
        missingBounds.removeValue(forKey: kCGWindowBounds as String)
        #expect(WindowInfo(normalizing: missingBounds) == nil)

        var badBounds = windowRow()
        badBounds[kCGWindowBounds as String] = "not-a-dictionary"
        #expect(WindowInfo(normalizing: badBounds) == nil)
    }

    @Test("absent title normalizes to nil, absent owner to empty")
    func optionalFields() {
        var row = windowRow(title: "Steam")
        row.removeValue(forKey: kCGWindowName as String)
        row.removeValue(forKey: kCGWindowOwnerName as String)
        let info = try! #require(WindowInfo(normalizing: row))
        #expect(info.windowTitle == nil)
        #expect(info.ownerName == "")
    }
}

// MARK: - Reducer

struct WindowReducerTests {
    @Test("appearance debounce: two positives reach visible")
    func appearanceDebounce() {
        let now = ContinuousClock.now
        var state = WindowReducerState()
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.phase == .unknown)
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.phase == .visible)
    }

    @Test("unknown plus miss stays unknown")
    func unknownMissStaysUnknown() {
        let now = ContinuousClock.now
        var state = WindowReducerState()
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.phase == .unknown)
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.phase == .unknown)
    }

    @Test("disappearance debounce: two misses reach hidden")
    func disappearanceDebounce() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.phase == .visible)
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.phase == .hidden)
    }

    @Test("reappearance debounce: hidden plus two positives reach visible")
    func reappearanceDebounce() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .hidden)
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.phase == .hidden)
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.phase == .visible)
    }

    @Test("opposite valid observation resets streak")
    func streakReset() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.negativeStreak == 1)
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.negativeStreak == 0)
        #expect(state.phase == .visible)
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.phase == .visible)
    }

    @Test("positive streak resets on miss in unknown")
    func positiveStreakReset() {
        let now = ContinuousClock.now
        var state = WindowReducerState()
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.positiveStreak == 1)
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.positiveStreak == 0)
        #expect(state.phase == .unknown)
    }

    @Test("ownershipIncomplete is fail-closed")
    func ownershipIncompleteFailClosed() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state.positiveStreak = 1
        state.negativeStreak = 1
        let preserved = WindowReducer.reduce(state, .ownershipIncomplete, now: now)
        #expect(preserved == state)
    }

    @Test("windowSnapshotFailed is fail-closed")
    func windowSnapshotFailedFailClosed() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state.positiveStreak = 1
        state.negativeStreak = 1
        let preserved = WindowReducer.reduce(state, .windowSnapshotFailed, now: now)
        #expect(preserved == state)
    }

    @Test("unsupported target preserves state and streaks")
    func unsupportedFailClosed() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .hidden)
        state.negativeStreak = 2
        let preserved = WindowReducer.reduce(state, .unsupported, now: now)
        #expect(preserved == state)
    }

    @Test("fail-closed observation counts as neither hit nor miss")
    func failClosedNeutral() {
        let now = ContinuousClock.now
        var state = WindowReducerState()
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        state = WindowReducer.reduce(state, .ownershipIncomplete, now: now)
        #expect(state.positiveStreak == 1)
        state = WindowReducer.reduce(state, .ownedPositive, now: now)
        #expect(state.phase == .visible)
    }

    @Test("foreignCandidatesOnly behaves as a miss")
    func foreignCandidatesOnlyBehavesAsMiss() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state = WindowReducer.reduce(state, .foreignCandidatesOnly, now: now)
        #expect(state.phase == .visible)
        state = WindowReducer.reduce(state, .foreignCandidatesOnly, now: now)
        #expect(state.phase == .hidden)
    }

    @Test("phase maps to running game session states")
    func phaseMapping() {
        #expect(WindowPhase.unknown.gameSessionState == .runningUnknown)
        #expect(WindowPhase.visible.gameSessionState == .runningVisible)
        #expect(WindowPhase.hidden.gameSessionState == .runningHidden)
    }

    // MARK: - Lease

    @Test("lease: visible degrades to unknown after leaseDuration with no proven observation")
    func leaseExpiredVisibleDegrades() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state.positiveStreak = WindowReducer.threshold
        state.lastProvenObservation = now - .seconds(2)
        let after = WindowReducer.applyLease(state, now: now)
        #expect(after.phase == .unknown)
    }

    @Test("lease: visible preserved when lease is fresh")
    func leaseFreshVisiblePreserved() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state.positiveStreak = WindowReducer.threshold
        state.lastProvenObservation = now
        let after = WindowReducer.applyLease(state, now: now)
        #expect(after.phase == .visible)
    }

    @Test("lease: unknown is not affected")
    func leaseDoesNotAffectUnknown() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .unknown)
        state.lastProvenObservation = nil
        let after = WindowReducer.applyLease(state, now: now)
        #expect(after.phase == .unknown)
    }

    @Test("lease: hidden is not affected")
    func leaseDoesNotAffectHidden() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .hidden)
        state.lastProvenObservation = now - .seconds(2)
        let after = WindowReducer.applyLease(state, now: now)
        #expect(after.phase == .hidden)
    }

    @Test("lease: visible with nil lastProvenObservation degrades immediately")
    func leaseNilObservationDegrades() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state.positiveStreak = WindowReducer.threshold
        state.lastProvenObservation = nil
        let after = WindowReducer.applyLease(state, now: now)
        #expect(after.phase == .unknown)
    }
}

// MARK: - Observer lifecycle

struct SessionWindowObserverLifecycleTests {
    @Test("stop cancellation invalidates the monitor") @MainActor
    func stopCancellation() {
        let observer = SessionWindowObserver(provider: MockWindowProvider())
        observer.startMonitoring(sessionID: UUID(), target: .steam, applyState: { _ in })
        #expect(observer.isMonitoring)
        observer.invalidate()
        #expect(!observer.isMonitoring)
    }

    @Test("one monitor per session: restart supersedes the previous task") @MainActor
    func oneMonitorPerSession() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam")]
        let observer = SessionWindowObserver(provider: provider)

        var appliedFirst: [GameSessionState] = []
        let firstSession = UUID()
        observer.startMonitoring(sessionID: firstSession, target: .steam, applyState: { appliedFirst.append($0) })
        let firstGeneration = observer.generation

        let secondSession = UUID()
        observer.startMonitoring(sessionID: secondSession, target: .steam, applyState: { _ in })

        #expect(observer.isMonitoring)
        #expect(observer.activeSessionID == secondSession)
        #expect(observer.generation != firstGeneration)

        let staleLease = MonitorLease(sessionID: firstSession, generation: firstGeneration)
        await observer.tickOnce(lease: staleLease)
        #expect(appliedFirst.isEmpty)
    }

    @Test("stale generation cannot apply state") @MainActor
    func staleGenerationRejection() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam")]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        let firstSession = UUID()
        observer.startMonitoring(sessionID: firstSession, target: .steam, applyState: { applied.append($0) })
        let staleGeneration = observer.generation

        observer.startMonitoring(sessionID: UUID(), target: .steam, applyState: { applied.append($0) })

        let staleLease = MonitorLease(sessionID: firstSession, generation: staleGeneration)
        await observer.tickOnce(lease: staleLease)
        #expect(applied.isEmpty)

        await observer.tickOnce(lease: observer.currentLease)
        #expect(!applied.isEmpty)
    }

    @Test("failed launch cleanup leaves no active monitor") @MainActor
    func failedLaunchCleanup() {
        let observer = SessionWindowObserver(provider: MockWindowProvider())
        observer.startMonitoring(sessionID: UUID(), target: .steam, applyState: { _ in })
        #expect(observer.isMonitoring)
        observer.invalidate()
        #expect(!observer.isMonitoring)
        #expect(observer.activeSessionID == nil)
    }

    @Test("recovery monitor start begins observation") @MainActor
    func recoveryMonitorStart() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "CloverPit")]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        let sessionID = UUID()
        observer.startMonitoring(sessionID: sessionID, target: .cloverPit, applyState: { applied.append($0) })

        #expect(observer.isMonitoring)
        #expect(observer.activeSessionID == sessionID)

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("async loop drives state from provider observations") @MainActor
    func asyncLoopDrivesState() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam")]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            pollInterval: .milliseconds(10),
            applyState: { applied.append($0) }
        )

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if applied.contains(.runningVisible) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        observer.invalidate()
        #expect(applied.contains(.runningVisible))
    }

    @Test("provider error preserves state") @MainActor
    func providerErrorFailClosed() async {
        let provider = MockWindowProvider()
        provider.shouldThrow = true
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(sessionID: UUID(), target: .steam, applyState: { applied.append($0) })

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("unsupported target preserves state and streaks") @MainActor
    func unsupportedTargetPreserved() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam")]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .unsupported,
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Session-scoped observation (ownership query)

    @Test("window owned outside the session tree is ignored") @MainActor
    func foreignOwnedWindowIgnored() async {
        let ownPID: Int32 = Int32(getpid())
        let provider = MockWindowProvider()
        let foreignPID: Int32 = 1
        provider.windows = [makeWindow(owner: "Steam", pid: foreignPID)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { [ownPID] in [ownPID] },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("window owned by the session root PID is accepted") @MainActor
    func sessionRootOwnedWindowAccepted() async {
        let ownPID: Int32 = Int32(getpid())
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: ownPID)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { [ownPID] in [ownPID] },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("window owned by a real descendant of the session root is accepted") @MainActor
    func sessionDescendantOwnedWindowAccepted() async throws {
        let ownPID: Int32 = Int32(getpid())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        try child.run()
        let childPID = child.processIdentifier
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: childPID)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { [ownPID, childPID] in [ownPID, childPID] },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("ownership returns nil → ownershipIncomplete preserved fail-closed") @MainActor
    func ownershipNilFailClosed() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { nil },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("foreign candidate when ownership present is foreignCandidatesOnly") @MainActor
    func foreignCandidatesOnlyWhenOwnershipPresent() async {
        let ownPID: Int32 = Int32(getpid())
        let provider = MockWindowProvider()
        provider.windows = [
            makeWindow(owner: "Steam", pid: 1),
            makeWindow(owner: "Steam", pid: 2),
            ]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { [ownPID] in [ownPID] },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("visible degrades to unknown when ownership goes nil after being visible") @MainActor
    func leaseDegradationOnOwnershipFailure() async {
        let ownPID: Int32 = Int32(getpid())
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: ownPID)]
        let observer = SessionWindowObserver(provider: provider)

        var ownershipEnabled = true
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { [ownPID] in
                ownershipEnabled ? [ownPID] : nil
            },
            pollInterval: .milliseconds(10),
            applyState: { applied.append($0) }
        )

        // Two positive ticks → visible
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        // Ownership now fails (nil) → fail-closed preserves visible, but
        // lastProvenObservation is not refreshed.
        ownershipEnabled = false
        // Drive past the lease duration
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            await observer.tickOnce(lease: observer.currentLease)
            try? await Task.sleep(for: .milliseconds(10))
        }
        observer.invalidate()
        #expect(applied.contains(.runningUnknown))
    }

    @Test("unscoped fallback: keyword match without ownership closure") @MainActor
    func unscopedKeywordFallback() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 999)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }
}
