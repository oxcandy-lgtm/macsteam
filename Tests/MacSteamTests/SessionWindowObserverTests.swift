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
    height: Double = 600,
    boundsX: Double = 0,
    boundsY: Double = 0,
    isOnscreen: Bool = false
    ) -> WindowInfo {
    WindowInfo(
        ownerPID: pid,
        ownerName: owner,
        windowTitle: title,
        layer: layer,
        alpha: alpha,
        boundsX: boundsX,
        boundsY: boundsY,
        boundsWidth: width,
        boundsHeight: height,
        isOnscreen: isOnscreen
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

    @Test("visible plus one miss stays visible")
    func visiblePlusOneMissStaysVisible() {
        let now = ContinuousClock.now
        var state = WindowReducerState(phase: .visible)
        state.positiveStreak = WindowReducer.threshold
        state = WindowReducer.reduce(state, .ownedMiss, now: now)
        #expect(state.phase == .visible)
        #expect(state.negativeStreak == 1)
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
    let nilOwnership: WindowOwnershipSnapshot = { nil }

    @Test("stop cancellation invalidates the monitor") @MainActor
    func stopCancellation() {
        let observer = SessionWindowObserver(provider: MockWindowProvider())
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: nilOwnership,
            applyState: { _ in }
        )
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
        observer.startMonitoring(
            sessionID: firstSession,
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { appliedFirst.append($0) }
        )
        let firstGeneration = observer.generation

        let secondSession = UUID()
        observer.startMonitoring(
            sessionID: secondSession,
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { _ in }
        )

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
        observer.startMonitoring(
            sessionID: firstSession,
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        let staleGeneration = observer.generation

        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        let staleLease = MonitorLease(sessionID: firstSession, generation: staleGeneration)
        await observer.tickOnce(lease: staleLease)
        #expect(applied.isEmpty)

        await observer.tickOnce(lease: observer.currentLease)
        #expect(!applied.isEmpty)
    }

    @Test("failed launch cleanup leaves no active monitor") @MainActor
    func failedLaunchCleanup() {
        let observer = SessionWindowObserver(provider: MockWindowProvider())
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: nilOwnership,
            applyState: { _ in }
        )
        #expect(observer.isMonitoring)
        observer.invalidate()
        #expect(!observer.isMonitoring)
        #expect(observer.activeSessionID == nil)
    }

    @Test("async loop drives state from provider observations") @MainActor
    func asyncLoopDrivesState() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
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
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: nilOwnership,
            applyState: { applied.append($0) }
        )

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
            ownershipSnapshot: nilOwnership,
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Ownership + target conjunction

    @Test("owned Steam window + Steam target reaches visible") @MainActor
    func ownedSteamWindowWithSteamTargetReachesVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("owned CloverPit window + CloverPit target reaches visible") @MainActor
    func ownedCloverPitWindowWithCloverPitTargetReachesVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "CloverPit", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .cloverPit,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("owned Steam window + CloverPit target never visible (cross-target)") @MainActor
    func ownedSteamWindowWithCloverPitTargetNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .cloverPit,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("owned CloverPit window + Steam target never visible (cross-target)") @MainActor
    func ownedCloverPitWindowWithSteamTargetNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "CloverPit", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("owned generic Wine window + Steam target never visible") @MainActor
    func ownedGenericWineWindowNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Wine", title: "Wine", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("owned Wine window with Steam title + Steam target reaches visible") @MainActor
    func ownedWineWindowWithSteamTitleReachesVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "wine", title: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("owned CrashPlan window (Steam title) + CloverPit target never visible") @MainActor
    func ownedCrashWindowWithWrongTargetNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Wine", title: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .cloverPit,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Ownership (P0-A / §5)

    @Test("missing ownership closure is rejected at compile time") @MainActor
    func ownershipClosureRequired() async {
        let provider = MockWindowProvider()
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

    // MARK: - Foreign / complete negative proof

    @Test("window owned outside the session tree is ignored") @MainActor
    func foreignOwnedWindowIgnored() async {
        let ownPID: Int32 = 100
        let provider = MockWindowProvider()
        let foreignPID: Int32 = 1
        provider.windows = [makeWindow(owner: "Steam", pid: foreignPID)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([ownPID]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("foreign target-matching candidates only") @MainActor
    func foreignTargetCandidatesOnly() async {
        let ownPID: Int32 = 100
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 1)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([ownPID]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Complete negative proof

    @Test("visible plus one complete miss stays visible") @MainActor
    func visiblePlusOneMissStaysVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        provider.windows = []
        await observer.tickOnce(lease: observer.currentLease)
        #expect(observer.currentLease != nil)
        #expect(applied.contains(.runningVisible))
    }

    @Test("visible plus two complete misses reaches hidden") @MainActor
    func visiblePlusTwoMissesReachesHidden() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        provider.windows = []
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningHidden))
    }

    @Test("unknown plus repeated miss stays unknown") @MainActor
    func unknownPlusRepeatedMissStaysUnknown() async {
        let provider = MockWindowProvider()
        provider.windows = []
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        for _ in 0..<5 {
            await observer.tickOnce(lease: observer.currentLease)
        }
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Provider / ownership failure

    @Test("provider failure: visible is never generated") @MainActor
    func providerFailureNeverVisible() async {
        let provider = MockWindowProvider()
        provider.shouldThrow = true
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )

        for _ in 0..<5 {
            await observer.tickOnce(lease: observer.currentLease)
        }
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("ownership failure: visible is never generated") @MainActor
    func ownershipFailureNeverVisible() async {
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

        for _ in 0..<5 {
            await observer.tickOnce(lease: observer.currentLease)
        }
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("visible degrades to unknown after lease expiry when ownership goes nil") @MainActor
    func leaseDegradationOnOwnershipFailure() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var ownershipEnabled = true
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(),
            target: .steam,
            ownershipSnapshot: { [ownPID = Int32(100)] in
                ownershipEnabled ? Set([ownPID]) : nil
            },
            pollInterval: .milliseconds(10),
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        ownershipEnabled = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            await observer.tickOnce(lease: observer.currentLease)
            try? await Task.sleep(for: .milliseconds(10))
        }
        observer.invalidate()
        #expect(applied.contains(.runningUnknown))
    }

    // MARK: - Lifecycle continuity

    @Test("duplicate launch does not invalidate existing monitor") @MainActor
    func duplicateLaunchDoesNotInvalidateExistingMonitor() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var applied: [GameSessionState] = []
        let firstSession = UUID()
        observer.startMonitoring(
            sessionID: firstSession,
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        let firstGeneration = observer.generation

        let secondSession = UUID()
        observer.startMonitoring(
            sessionID: secondSession,
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { _ in }
        )

        // Stale monitor from first session cannot apply state.
        let staleLease = MonitorLease(sessionID: firstSession, generation: firstGeneration)
        await observer.tickOnce(lease: staleLease)
        #expect(applied.isEmpty)

        // Current monitor is active.
        #expect(observer.activeSessionID == secondSession)
        #expect(observer.generation != firstGeneration)
    }

    @Test("new session cannot receive previous session state") @MainActor
    func newSessionCannotReceivePreviousSessionState() async {
        let provider = MockWindowProvider()
        let observer = SessionWindowObserver(provider: provider)

        var firstApplied: [GameSessionState] = []
        let firstSession = UUID()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        observer.startMonitoring(
            sessionID: firstSession,
            target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { firstApplied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(firstApplied.contains(.runningVisible))

        var secondApplied: [GameSessionState] = []
        let secondSession = UUID()
        observer.startMonitoring(
            sessionID: secondSession,
            target: .steam,
            ownershipSnapshot: { nil },
            applyState: { secondApplied.append($0) }
        )

        // Stale ticks from first session must not reach second session's callback.
        let staleLease = MonitorLease(sessionID: firstSession, generation: observer.generation - 1)
        await observer.tickOnce(lease: staleLease)
        #expect(secondApplied.isEmpty)
    }
}

// MARK: - R3 Window Authority Regression Tests

/// Production-linked regression tests for U1R18-R3 ownership-bound window
/// detection. Each test drives through the real `SessionWindowObserver` →
/// `observe` → `ownershipSnapshot` pipeline.
struct R3WindowAuthorityRegressionTests {

    // MARK: - Positive path (owned + target identity)

    @Test("owned Steam + Steam target reaches visible") @MainActor
    func ownedSteamSteamTargetVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    @Test("owned CloverPit + CloverPit target reaches visible") @MainActor
    func ownedCloverPitCloverPitTargetVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "CloverPit", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .cloverPit,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))
    }

    // MARK: - Cross-target rejection

    @Test("owned Steam + CloverPit target never visible") @MainActor
    func ownedSteamCloverPitTargetNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .cloverPit,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("owned CloverPit + Steam target never visible") @MainActor
    func ownedCloverPitSteamTargetNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "CloverPit", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Generic owned window rejection

    @Test("owned generic Wine window never visible") @MainActor
    func ownedGenericWineNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Wine", title: "Wine", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Foreign candidate rejection

    @Test("foreign Steam candidate never visible") @MainActor
    func foreignSteamCandidateNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 1)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("foreign CloverPit candidate never visible") @MainActor
    func foreignCloverPitCandidateNeverVisible() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "CloverPit", pid: 1)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .cloverPit,
            ownershipSnapshot: { Set([Int32(100)]) },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Ownership failure (nil closure)

    @Test("ownership nil with target window present stays unknown") @MainActor
    func ownershipNilWithTargetWindowStaysUnknown() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { nil },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    @Test("ownership nil with non-target geometry window stays unknown") @MainActor
    func ownershipNilWithNonTargetGeometryWindowStaysUnknown() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Wine", title: "Wine", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { nil },
            applyState: { applied.append($0) }
        )
        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.allSatisfy { $0 == .runningUnknown })
    }

    // MARK: - Visible + failure (fail-closed, never hidden from failure)

    @Test("visible + provider failure degrades to unknown, never hidden") @MainActor
    func visiblePlusProviderFailureDegradesToUnknown() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { Set([Int32(100)]) },
            pollInterval: .milliseconds(10),
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        provider.shouldThrow = true
        applied.removeAll()

        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            await observer.tickOnce(lease: observer.currentLease)
            try? await Task.sleep(for: .milliseconds(10))
        }
        observer.invalidate()
        #expect(applied.contains(.runningUnknown))
        #expect(!applied.contains(.runningHidden))
    }

    @Test("visible + ownership failure degrades to unknown, never hidden") @MainActor
    func visiblePlusOwnershipFailureDegradesToUnknown() async {
        let provider = MockWindowProvider()
        provider.windows = [makeWindow(owner: "Steam", pid: 100)]
        let observer = SessionWindowObserver(provider: provider)

        var ownershipEnabled = true
        var applied: [GameSessionState] = []
        observer.startMonitoring(
            sessionID: UUID(), target: .steam,
            ownershipSnapshot: { [ownPID = Int32(100)] in
                ownershipEnabled ? Set([ownPID]) : nil
            },
            pollInterval: .milliseconds(10),
            applyState: { applied.append($0) }
        )

        await observer.tickOnce(lease: observer.currentLease)
        await observer.tickOnce(lease: observer.currentLease)
        #expect(applied.contains(.runningVisible))

        ownershipEnabled = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            await observer.tickOnce(lease: observer.currentLease)
            try? await Task.sleep(for: .milliseconds(10))
        }
        observer.invalidate()
        #expect(applied.contains(.runningUnknown))
        #expect(!applied.contains(.runningHidden))
    }
}
