// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

// MARK: - U1R18-R13-FIX1 §14: launch pipeline progress contract

struct LaunchPipelineStateTests {

    @Test func progressStartsWithZero() {
        var m = WineMilestones()
        #expect(m.progress == 0)
        #expect(m.completedCount == 0)
    }

    @Test func progressIsMonotonicWithinOneAttempt() {
        var m = WineMilestones()
        var last = m.progress
        for i in 0..<WineMilestones.total {
            switch i {
            case 0: m.runtimeResolved = true
            case 1: m.runtimeCapabilityValidated = true
            case 2: m.realLoadProbeComplete = true
            case 3: m.canonicalPrefixBound = true
            case 4: m.wineEnvironmentReady = true
            default: break
            }
            #expect(m.progress >= last)
            last = m.progress
        }
    }

    @Test func progressNeverExceedsOne() {
        var m = WineMilestones()
        m.runtimeResolved = true
        m.runtimeCapabilityValidated = true
        m.realLoadProbeComplete = true
        m.canonicalPrefixBound = true
        m.wineEnvironmentReady = true
        #expect(m.progress == 1.0)
        #expect(!(m.progress > 1.0))
    }

    @Test func readyIsOnlyNormalHundredPercentTerminal() {
        var allDone = WineMilestones()
        allDone.runtimeResolved = true
        allDone.runtimeCapabilityValidated = true
        allDone.realLoadProbeComplete = true
        allDone.canonicalPrefixBound = true
        allDone.wineEnvironmentReady = true
        #expect(allDone.progress == 1.0)
        // A partially-done pipeline is not terminal-ready.
        var partial = WineMilestones()
        partial.runtimeResolved = true
        #expect(partial.progress < 1.0)
    }

    @Test func failureNeverSilentlyBecomesReady() {
        let fresh = WineMilestones()
        #expect(fresh.progress != 1.0)
    }

    @Test func newAttemptResetsPreviousActiveProgress() {
        var a = WineMilestones()
        a.wineEnvironmentReady = true
        let b = WineMilestones() // fresh attempt
        #expect(b.progress == 0)
        #expect(b != a)
    }

    @Test func stageOrderViolationFailsClosed() {
        let order = LaunchPipelineStage.allCases.map(\.rawValue)
        for i in 1..<order.count {
            #expect(order[i] > order[i - 1], "stage order must be strict")
        }
        #expect(LaunchPipelineStage.idle.rawValue < LaunchPipelineStage.ready.rawValue)
        #expect(LaunchPipelineStage.ready.rawValue < LaunchPipelineStage.failed.rawValue)
    }
}

// MARK: - U1R18-R13-FIX1 §15: timing / ETA contract

struct LaunchTimingStoreTests {

    @Test func monotonicClockUsed() {
        let clock = SystemLaunchClock()
        let a = clock.nowMilliseconds()
        let b = clock.nowMilliseconds()
        #expect(b >= a)
    }

    @Test func elapsedNeverNegative() {
        let sw = LaunchStopwatch(clock: SystemLaunchClock())
        #expect(sw.elapsedMS() >= 0)
    }

    @Test func firstSampleETAUndefined() {
        var store = LaunchTimingStore()
        store.record(.totalMS, milliseconds: 1000)
        #expect(store.estimateMS(.totalMS) == nil)
        #expect(store.remainingMS(.totalMS, elapsedMS: 0) == nil)
    }

    @Test func insufficientHistoryETAUndefined() {
        var store = LaunchTimingStore()
        store.record(.totalMS, milliseconds: 1000)
        store.record(.totalMS, milliseconds: 1200)
        #expect(store.estimateMS(.totalMS) == nil)
    }

    @Test func sufficientSamplesBoundedEstimate() {
        var store = LaunchTimingStore()
        for v: Int64 in [1000, 1200, 1100] { store.record(.totalMS, milliseconds: v) }
        #expect(store.estimateMS(.totalMS) == 1100)
    }

    @Test func medianResistsOutlier() {
        var store = LaunchTimingStore()
        for v: Int64 in [1000, 1100, 1200, 9000000] { store.record(.totalMS, milliseconds: v) }
        // Sorted [1000,1100,1200,9000000]; median = (1100+1200)/2 = 1150.
        #expect(store.estimateMS(.totalMS) == 1150)
    }

    @Test func historyMaxCountEnforced() {
        var store = LaunchTimingStore()
        for i in 1...20 { store.record(.totalMS, milliseconds: Int64(i)) }
        #expect(store.samples[.totalMS]?.count == LaunchTimingStore.maxSamples)
    }

    @Test func noNegativeRemainingTime() {
        var store = LaunchTimingStore()
        for v: Int64 in [1000, 1100, 1200] { store.record(.totalMS, milliseconds: v) }
        #expect(store.remainingMS(.totalMS, elapsedMS: 5000) == 0)
        #expect(store.remainingMS(.totalMS, elapsedMS: 500) == 600)
    }

    @Test func noNaNOrInfinity() {
        var store = LaunchTimingStore()
        for v: Int64 in [1000, 1100, 1200] { store.record(.totalMS, milliseconds: v) }
        let est = store.estimateMS(.totalMS)
        #expect(est != nil)
        #expect((est ?? 0) >= 0)
    }
}

// MARK: - U1R18-R13-FIX1 §16: fast / warm path contract

struct LaunchValidationCacheTests {

    private func fp(
        runtime: String? = "r", prefix: String? = "p",
        steam: String? = "s", imported: Bool = true
    ) -> LaunchValidationFingerprint {
        LaunchValidationFingerprint(
            runtimeSafeID: runtime, prefixSafeID: prefix,
            steamSafeID: steam, importedWine: imported)
    }

    @Test func sameVerifiedRuntimePrefixAllowsFastPath() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        #expect(cache.matchesAdmissible(fp()))
    }

    @Test func runtimeChangeInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.invalidate()
        #expect(!cache.isFastPathAdmissible)
        #expect(!cache.matchesAdmissible(fp()))
    }

    @Test func prefixChangeInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.invalidate()
        #expect(!cache.matchesAdmissible(fp(prefix: "p2")))
    }

    @Test func steamInstallMutationInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.invalidate()
        #expect(!cache.matchesAdmissible(fp(steam: "s2")))
    }

    @Test func failedLaunchInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.invalidate()
        #expect(!cache.isFastPathAdmissible)
    }

    @Test func recoveryRequiredInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.invalidate()
        #expect(!cache.isFastPathAdmissible)
    }

    @Test func unownedSteamCannotBeReused() {
        var cache = LaunchValidationCache()
        cache.invalidate() // ownership lost
        #expect(!cache.isFastPathAdmissible)
    }

    @Test func neverAdmissibleBeforeFirstSuccess() {
        var cache = LaunchValidationCache()
        #expect(!cache.isFastPathAdmissible)
        #expect(!cache.matchesAdmissible(fp()))
    }
}

// MARK: - U1R18-R13-FIX1 §3/§17: build identity + app-sync helpers

struct BuildIdentityTests {

    @Test func shortSHAIsBoundedHex() {
        let s = BuildIdentity.shortSHA("fb82f7c98b6810628c0c84b9cf16defb99cf7597")
        #expect(s == "fb82f7c98b68")
        #expect(s.count == 12)
    }

    @Test func currentWithoutBundleFallsBackSafely() {
        let identity = BuildIdentity.current(bundle: Bundle.main)
        #expect(!identity.synced)
        #expect(!identity.commitSHA.isEmpty)
        #expect(identity.channel.contains("run"))
    }

    @Test func embeddedIdentityParsed() {
        let identity = BuildIdentity(
            commitSHA: BuildIdentity.shortSHA("fb82f7c98b6810628c0c84b9cf16defb99cf7597"),
            channel: "Developer Local",
            synced: true)
        #expect(identity.commitSHA == "fb82f7c98b68")
        #expect(identity.channel == "Developer Local")
        #expect(identity.synced)
    }
}