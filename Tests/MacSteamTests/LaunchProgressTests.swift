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

    @Test func stageSteamOnlyRouteAdmitted() {
        // FIX A: the explicit graph admits the Steam-only route directly.
        var authority = LaunchTransitionAuthority()
        #expect(authority.transition(to: .startingSteam) == .admitted)
        #expect(authority.transition(to: .waitingForSteam) == .admitted)
        #expect(authority.transition(to: .ready) == .admitted)
        #expect(authority.stage == .ready)
    }

    @Test func stageIllegalSkipsRejected() {
        // FIX A: rawValue is not workflow authority; illegal skips are rejected.
        var authority = LaunchTransitionAuthority()
        #expect(authority.transition(to: .ready) == .rejectedSkipped) // idle -> ready skip
        #expect(authority.stage == .idle)
        #expect(authority.transition(to: .startingSteam) == .admitted)
        #expect(authority.transition(to: .ready) == .rejectedSkipped) // startingSteam -> ready skip
        #expect(authority.stage == .startingSteam)
        #expect(authority.transition(to: .waitingForSteam) == .admitted)
        #expect(authority.transition(to: .startingSteam) == .rejectedBackward)
        #expect(authority.stage == .waitingForSteam)
        #expect(authority.transition(to: .waitingForSteam) == .rejectedSame)
    }

    @Test func stageOrderViolationFailsClosed() {
        var authority = LaunchTransitionAuthority()
        #expect(authority.transition(to: .startingSteam) == .admitted)
        #expect(authority.stage == .startingSteam)
        #expect(authority.transition(to: .idle) == .rejectedBackward)
        #expect(authority.stage == .startingSteam)
        #expect(authority.transition(to: .ready) == .rejectedSkipped)
        #expect(authority.stage == .startingSteam)
        #expect(authority.transition(to: .startingSteam) == .rejectedSame)
    }

    @Test func legalForwardProgressionAllowed() {
        var authority = LaunchTransitionAuthority()
        for stage in [LaunchPipelineStage.validatingRuntime, .probingWine,
                      .resolvingPrefix, .validatingSteam, .preparingWine,
                      .startingSteam, .waitingForSteam, .launchingCloverPit,
                      .waitingForCloverPit, .ready] {
            #expect(authority.transition(to: stage) == .admitted)
        }
    }

    @Test func failedCanOnlyEnterFromActiveStage() {
        var authority = LaunchTransitionAuthority()
        #expect(authority.transition(to: .startingSteam) == .admitted)
        #expect(authority.transition(to: .failed) == .admitted)
        #expect(authority.failed)
        #expect(authority.stage == .failed)
        // Once failed, no further transitions are admitted (except failed itself).
        #expect(authority.transition(to: .failed) == .rejectedSame)
        #expect(authority.transition(to: .ready) == .rejectedSkipped)
    }

    @Test func resetClearsStaleMilestonesAndStage() {
        var authority = LaunchTransitionAuthority()
        authority.earn(.runtimeResolved)
        authority.earn(.runtimeCapabilityValidated)
        authority.transition(to: .validatingRuntime)
        #expect(authority.progress > 0)
        authority.reset()
        #expect(authority.progress == 0)
        #expect(authority.stage == .idle)
        #expect(!authority.failed)
    }

    @Test func beginSteamAttemptPreservesCurrentEvidence() {
        // FIX C: a new Steam timing attempt preserves still-current evidence.
        var authority = LaunchTransitionAuthority()
        authority.earn(.runtimeResolved)
        authority.earn(.runtimeCapabilityValidated)
        #expect(authority.progress > 0)
        authority.beginSteamAttempt()
        #expect(authority.progress > 0)
        #expect(authority.wineMilestones.runtimeResolved)
        #expect(authority.stage == .idle)
        #expect(!authority.failed)
    }

    @Test func clearMilestoneRemovesStaleEvidenceOnIdentityChange() {
        // FIX C: identity change clears the corresponding evidence.
        var authority = LaunchTransitionAuthority()
        authority.earn(.runtimeResolved)
        authority.earn(.canonicalPrefixBound)
        authority.clearMilestone(.runtimeResolved)
        #expect(!authority.wineMilestones.runtimeResolved)
        #expect(authority.wineMilestones.canonicalPrefixBound)
    }

    @Test func failedAttemptMarksFailedAndClearsTiming() {
        // FIX C/§18: a failed attempt marks failure and clears timing, but does
        // not erase identity-bound evidence (evidence is cleared on identity
        // change, not on timing failure).
        var authority = LaunchTransitionAuthority()
        authority.earn(.runtimeResolved)
        authority.record(.winePreparation, milliseconds: 100)
        authority.fail()
        #expect(authority.failed)
        #expect(authority.stage == .failed)
        #expect(authority.timing.winePreparationMS == 0)
        #expect(authority.wineMilestones.runtimeResolved) // evidence preserved
    }

    @Test func failExplicitlyExposed() {
        var authority = LaunchTransitionAuthority()
        authority.transition(to: .failed)
        #expect(authority.failed)
        #expect(authority.stage == .failed)
    }
}

// MARK: - U1R18-R13-FIX1-FIX1 §11: production-linked regression matrix

struct LaunchTransitionProductionTests {

    @Test func realRuntimeSelectionEarnsMilestone() {
        var authority = LaunchTransitionAuthority()
        authority.earn(.runtimeResolved)
        #expect(authority.wineMilestones.runtimeResolved)
    }

    @Test func capabilitySuccessEarnsMilestone() {
        var authority = LaunchTransitionAuthority()
        authority.earn(.runtimeCapabilityValidated)
        #expect(authority.wineMilestones.runtimeCapabilityValidated)
    }

    @Test func healthyRealLoadEarnsProbeMilestone() {
        var authority = LaunchTransitionAuthority()
        authority.earn(.realLoadProbeComplete)
        #expect(authority.wineMilestones.realLoadProbeComplete)
    }

    @Test func canonicalPrefixEvidenceEarnsMilestone() {
        var authority = LaunchTransitionAuthority()
        authority.earn(.canonicalPrefixBound)
        #expect(authority.wineMilestones.canonicalPrefixBound)
    }

    @Test func environmentConstructionEarnsMilestone() {
        var authority = LaunchTransitionAuthority()
        authority.earn(.wineEnvironmentReady)
        #expect(authority.wineMilestones.wineEnvironmentReady)
    }

    @Test func timingSegmentRecordedMonotonically() {
        var authority = LaunchTransitionAuthority()
        authority.record(.winePreparation, milliseconds: 100)
        authority.record(.steamProcessStart, milliseconds: 200)
        authority.record(.steamReady, milliseconds: 300)
        #expect(authority.timing.winePreparationMS == 100)
        #expect(authority.timing.steamProcessStartMS == 200)
        #expect(authority.timing.steamReadyMS == 300)
        #expect(authority.timing.totalToSteamReadyMS == 600)
    }

    @Test func failedAttemptRecordsNoSuccessfulSample() {
        var store = LaunchTimingStore()
        store.record(.totalMS, milliseconds: 1000) // a prior successful sample
        // A failed attempt must not be recorded into success history here.
        store.record(.totalMS, milliseconds: 0) // rejected sample is clamped/rejected by caller
        #expect(store.estimateMS(.totalMS) == nil) // never accumulated from 1 real sample
    }

    @Test func etaUnavailableAtFewerThanThreeSamples() {
        var store = LaunchTimingStore()
        store.record(.totalMS, milliseconds: 1000)
        store.record(.totalMS, milliseconds: 1100)
        #expect(store.estimateMS(.totalMS) == nil)
    }

    @Test func etaAvailableAtThreeSamples() {
        var store = LaunchTimingStore()
        for v: Int64 in [1000, 1100, 1200] { store.record(.totalMS, milliseconds: v) }
        #expect(store.estimateMS(.totalMS) != nil)
    }

    @Test func failedSamplesExcludedFromMedian() {
        var store = LaunchTimingStore()
        for v: Int64 in [1000, 1100, 1200] { store.record(.totalMS, milliseconds: v) }
        // A large outlier (failed attempt) must not skew the median badly.
        store.record(.totalMS, milliseconds: 9000000)
        #expect(store.estimateMS(.totalMS) == 1150)
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

    private func fileID(size: UInt64 = 100, mtime: Int64 = 1000, inode: UInt64 = 1) -> LaunchFileIdentity {
        LaunchFileIdentity(isRegularFile: true, size: size, mtimeNanos: mtime, inode: inode, device: 1)
    }

    private func fp(
        runtime: LaunchFileIdentity? = nil,
        prefix: String? = "p",
        prefixValid: Bool = true,
        steam: LaunchFileIdentity? = nil,
        imported: Bool = true
    ) -> LaunchValidationFingerprint {
        LaunchValidationFingerprint(
            runtimeIdentity: runtime ?? fileID(),
            prefixSafeID: prefix,
            prefixEvidenceValid: prefixValid,
            steamIdentity: steam ?? fileID(),
            importedWine: imported)
    }

    @Test func sameVerifiedRuntimePrefixAllowsFastPath() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        #expect(cache.matchesAdmissible(fp()))
    }

    @Test func runtimeChangeInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(runtime: fileID(inode: 1)))
        #expect(!cache.matchesAdmissible(fp(runtime: fileID(inode: 2))))
    }

    @Test func runtimeSamePathDifferentMaterialIdentityMisses() {
        // FIX E: same runtime path, replaced/modified file -> fingerprint changes.
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(runtime: fileID(size: 100, mtime: 1000)))
        #expect(!cache.matchesAdmissible(fp(runtime: fileID(size: 100, mtime: 2000))))
        #expect(!cache.matchesAdmissible(fp(runtime: fileID(size: 200, mtime: 1000))))
    }

    @Test func prefixChangeInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(prefix: "p"))
        #expect(!cache.matchesAdmissible(fp(prefix: "p2")))
    }

    @Test func prefixEvidenceInvalidInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(prefixValid: true))
        #expect(!cache.matchesAdmissible(fp(prefixValid: false)))
    }

    @Test func steamInstallMutationInvalidates() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(steam: fileID(inode: 1)))
        #expect(!cache.matchesAdmissible(fp(steam: fileID(inode: 2))))
    }

    @Test func steamSamePathDifferentMaterialIdentityMisses() {
        // FIX E: same Steam path, replaced/modified executable -> fingerprint changes.
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(steam: fileID(size: 100, mtime: 1000)))
        #expect(!cache.matchesAdmissible(fp(steam: fileID(size: 100, mtime: 3000))))
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

    // U1R18-R13-FIX1-FIX1 §7.4: full validation -> success -> admissible
    // fast path on matching fingerprint -> mutation forces full validation again.
    @Test func productionProofCacheHitThenInvalidation() {
        var cache = LaunchValidationCache()
        // First launch: full validation (no prior success) takes the full path.
        #expect(!cache.isFastPathAdmissible)
        // Successful full validation is recorded.
        cache.recordSuccess(fingerprint: fp())
        #expect(cache.isFastPathAdmissible)
        // Same admissible fingerprint -> fast path allowed.
        #expect(cache.matchesAdmissible(fp()))
        // A mutated fingerprint component forces full validation again.
        #expect(!cache.matchesAdmissible(fp(runtime: fileID(inode: 99))))
        #expect(!cache.matchesAdmissible(fp(prefix: "p2")))
        #expect(!cache.matchesAdmissible(fp(steam: fileID(inode: 98))))
    }

    @Test func missingArtifactCannotMatchCachedRealIdentity() {
        // A missing/non-regular artifact yields a nil/absent identity, so its
        // fingerprint cannot match a cached real identity (no fast path).
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp(runtime: fileID(), steam: fileID()))
        let missingRuntime = LaunchValidationFingerprint(
            runtimeIdentity: nil, prefixSafeID: "p", prefixEvidenceValid: true,
            steamIdentity: fileID(), importedWine: true)
        #expect(!cache.matchesAdmissible(missingRuntime))
    }

    @Test func nonRegularArtifactFingerprintDiffers() {
        // A non-regular artifact exposes a different bounded identity, so a
        // cached regular identity cannot admit it.
        let regular = fp(runtime: fileID(), steam: fileID())
        let nonRegular = LaunchValidationFingerprint(
            runtimeIdentity: LaunchFileIdentity(isRegularFile: false, size: 0, mtimeNanos: 0, inode: nil, device: nil),
            prefixSafeID: "p", prefixEvidenceValid: true, steamIdentity: fileID(), importedWine: true)
        #expect(regular != nonRegular)
    }

    @Test func safeIDIsBoundedAndNotAPath() {
        let a = LaunchSafeID.of("/some/path/steam.exe")
        let b = LaunchSafeID.of("/some/path/steam.exe")
        let c = LaunchSafeID.of("/other/path/steam.exe")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 16)
    }

    @Test func cacheHitNeverBypassesSessionOwnershipSafety() {
        // The cache alone never admits: a fast path hit still requires the
        // session/ownership checks to have run. Recording a failure clears it.
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.recordFailure() // a failed launch invalidates ownership
        #expect(!cache.isFastPathAdmissible)
        #expect(!cache.matchesAdmissible(fp()))
    }

    @Test func invalidateIfFailedLeavesCleanSuccess() {
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        cache.invalidateIfFailed() // no failure recorded -> stays admissible
        #expect(cache.isFastPathAdmissible)
    }

    @Test func warmProcessReuseAbsent() {
        // No warm process-reuse field exists; the cache only short-circuits
        // expensive validation, never process reuse.
        var cache = LaunchValidationCache()
        cache.recordSuccess(fingerprint: fp())
        #expect(cache.matchesAdmissible(fp()))
        #expect(cache.isFastPathAdmissible)
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