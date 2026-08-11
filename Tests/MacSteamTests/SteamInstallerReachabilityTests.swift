// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MacSteam

/// Deterministic proof for the production Steam installer step policy.
///
/// These tests intentionally exercise presentation policy only. File choice,
/// verification, and installation remain owned by the production view and
/// coordinator flow.
struct SteamInstallerReachabilityTests {

    @Test func initialStateMakesDownloadAndSelectionReachable() {
        let policy = SteamInstallerStepPolicy(
            hasInstallerSelection: false,
            isVerified: false,
            setupState: .prefixReady,
            installLifecycle: .absent
        )

        #expect(policy.downloadState == .ready)
        #expect(policy.selectState == .ready)
        #expect(policy.installState == .pending)
        #expect(policy.installActionEnabled == false)
    }

    @Test func selectedUnverifiedKeepsSelectionReachableAndInstallBlocked() {
        let policy = SteamInstallerStepPolicy(
            hasInstallerSelection: true,
            isVerified: false,
            setupState: .steamInstallerRequired,
            installLifecycle: .absent
        )

        #expect(policy.downloadState == .completed)
        #expect(policy.selectState == .ready)
        #expect(policy.installState == .pending)
        #expect(policy.installActionEnabled == false)
    }

    @Test func verifiedSelectionMakesInstallReadyAndEnabled() {
        let policy = SteamInstallerStepPolicy(
            hasInstallerSelection: true,
            isVerified: true,
            setupState: .steamInstallerVerified,
            installLifecycle: .absent
        )

        #expect(policy.downloadState == .completed)
        #expect(policy.selectState == .completed)
        #expect(policy.installState == .ready)
        #expect(policy.installActionEnabled)
    }

    @Test func lifecycleStillOwnsWorkingAndCompletedInstallPresentation() {
        let installing = SteamInstallerStepPolicy(
            hasInstallerSelection: true,
            isVerified: true,
            setupState: .steamInstallationPending,
            installLifecycle: .installing
        )
        let completed = SteamInstallerStepPolicy(
            hasInstallerSelection: true,
            isVerified: true,
            setupState: .steamReady,
            installLifecycle: .verifiedComplete
        )

        #expect(installing.installState == .working)
        #expect(installing.installActionEnabled == false)
        #expect(completed.installState == .completed)
        #expect(completed.installActionEnabled == false)
    }

    @Test func policyDoesNotAutoSelectOrAutoDownloadAnInstaller() {
        let policy = SteamInstallerStepPolicy(
            hasInstallerSelection: false,
            isVerified: false,
            setupState: .prefixReady,
            installLifecycle: .absent
        )

        // Reachability is exposed without manufacturing either selection or
        // verification; the production NSOpenPanel/coordinator route remains
        // the only path that can make the installer verified.
        #expect(policy.selectState == .ready)
        #expect(policy.installActionEnabled == false)
    }
}
