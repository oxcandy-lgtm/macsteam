// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

/// Deterministic monotonic clock for the FIX5 live ETA proof.
final class ManualMonotonicLaunchClock: @unchecked Sendable, LaunchClock {
    var nowMS: Int64
    init(_ nowMS: Int64 = 0) { self.nowMS = nowMS }
    func nowMilliseconds() -> Int64 { nowMS }
}

/// U1R18-R13-FIX1-FIX5 §4: the ACTIVE coordinator live ETA proof against a
/// fake monotonic clock. The LaunchTimingStore unit proofs alone are not
/// sufficient: this drives a real coordinator into `.waitingForSteam` and shows
/// the production ``steamReadyETA`` remaining strictly decreasing towards zero
/// as a monotonic clock advances. No sleep, no Date(), no wall clock.
struct LaunchLiveETATests {

    private func fileID(size: UInt64 = 100, mtime: Int64 = 1000, inode: UInt64 = 1) -> LaunchFileIdentity {
        LaunchFileIdentity(isRegularFile: true, size: size, mtimeNanos: mtime, inode: inode, device: 1)
    }

    private func tempPrefix() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("akiyalife-eta-test-prefix-\(UUID().uuidString)")
    }

    private func makeRuntimeDir(_ root: URL) -> URL {
        let bin = root.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try? Data("wine".utf8).write(to: wine)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        return root
    }

    @MainActor
    private func makeCoordinatorAt(
        prefixRoot: URL,
        fileIdentity: FakeLaunchFileIdentityProvider,
        clock: any LaunchClock
    ) -> UltimateSetupCoordinator {
        let fm = FileManager.default
        try? fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixRoot.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixRoot.appendingPathComponent("drive_c/users"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixRoot.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
        let steamDir = prefixRoot.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try? fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try? Data("steam".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        let coordinator = UltimateSetupCoordinator(
            launchClock: clock,
            fileIdentityProvider: fileIdentity
        )
        let validStaged = PrefixInspection(prefixURL: prefixRoot, driveCExists: true,
                                     hasWinePrefix: true, hasSteam: true, isValid: true)
        coordinator.prefixInspectorProvider = { FakePrefixInspector2(validStaged) }
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixRoot)
        _ = coordinator.establishPrefixEvidence(for: coordinator.prefixLayout!, source: PrefixAcquisitionSource.existingCanonical)
        return coordinator
    }

    /// Seed >= minimum successful total samples so the ETA is defined.
    @MainActor
    private func seedSuccessfulHistory(_ coordinator: UltimateSetupCoordinator) {
        for _ in 0..<LaunchTimingStore.minimumSamples {
            coordinator.recordLaunchTimingSegment(.winePreparation, milliseconds: 3000)
            coordinator.recordLaunchTimingSegment(.steamProcessStart, milliseconds: 1000)
            coordinator.recordLaunchTimingSegment(.steamReady, milliseconds: 2000)
            coordinator.recordSuccessfulTimingSample()
        }
    }

    @MainActor
    @Test func activeWaitingForSteamEtaRemainingStrictlyDecreasesMonotonic() {
        // Historical total per sample: 3000+1000+2000 = 6000ms.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let clock = ManualMonotonicLaunchClock(10_000)
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake, clock: clock)
        seedSuccessfulHistory(coordinator)
        #expect(coordinator.startupTelemetry.hasSufficientEtaHistory)

        // Active launch into `.waitingForSteam` with a live base of
        // wine(3000) + steamProcessStart(1000) = 4000ms.
        coordinator.beginSteamAttempt()
        coordinator.recordLaunchTimingSegment(.winePreparation, milliseconds: 3000)
        coordinator.recordLaunchTimingSegment(.steamProcessStart, milliseconds: 1000)
        coordinator.requireLaunchTransition(to: .startingSteam)
        coordinator.requireLaunchTransition(to: .waitingForSteam)

        // Deterministic wait boundary armed at t0.
        #expect(coordinator.armSteamReadyWaitForTesting())

        let delta: Int64 = 500
        clock.nowMS = 10_000 // t0
        let t0 = coordinator.steamReadyETA
        #expect(t0 != nil)
        clock.nowMS = 10_000 + delta // t0 + Δ
        let t1 = coordinator.steamReadyETA
        #expect(t1 != nil)
        clock.nowMS = 10_000 + 2 * delta // t0 + 2Δ
        let t2 = coordinator.steamReadyETA
        #expect(t2 != nil)

        // Live elapsed strictly increases.
        #expect(t0!.elapsed < t1!.elapsed)
        #expect(t1!.elapsed < t2!.elapsed)

        // Remaining strictly decreases across the first interval and never
        // increases across the second (>= towards zero).
        #expect(t0!.remaining != nil)
        #expect(t1!.remaining != nil)
        #expect(t2!.remaining != nil)
        #expect(t0!.remaining! > t1!.remaining!)
        #expect(t1!.remaining! >= t2!.remaining!)
        #expect(t2!.remaining! >= 0)

        // Explicit decreasing value check toward zero.
        #expect(t0!.elapsed == 4000)
        #expect(t1!.elapsed == 4500)
        #expect(t2!.elapsed == 5000)
        #expect(t0!.remaining == 2000)
        #expect(t1!.remaining == 1500)
        #expect(t2!.remaining == 1000)
    }

    @MainActor
    @Test func etaRemainingNeverNegativeBeyondEstimate() {
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let clock = ManualMonotonicLaunchClock(10_000)
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake, clock: clock)
        seedSuccessfulHistory(coordinator)

        coordinator.beginSteamAttempt()
        coordinator.recordLaunchTimingSegment(.winePreparation, milliseconds: 3000)
        coordinator.recordLaunchTimingSegment(.steamProcessStart, milliseconds: 1000)
        coordinator.requireLaunchTransition(to: .startingSteam)
        coordinator.requireLaunchTransition(to: .waitingForSteam)
        #expect(coordinator.armSteamReadyWaitForTesting())

        // Far beyond the 6000ms estimate: remaining clamps to zero, never
        // negative.
        clock.nowMS = 10_000 + 100_000
        let far = coordinator.steamReadyETA
        #expect(far != nil)
        #expect(far!.elapsed == 104_000)
        #expect(far!.remaining == 0)
    }
}
