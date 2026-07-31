// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import MacsTeamNavigationCore
@testable import MacSteam

// MARK: - U1R17-C functional navigation tests
//
// These tests exercise the SAME resolver/presentation model used by
// production (UltimatePageResolver + coordinator.send) — not just
// InstallerPage.allCases ordering or step numbers.

struct SteamSurfaceResolutionTests {
    @Test("steamInstaller resolves to installer surface")
    func steamInstaller_installerSurface() {
        #expect(UltimatePageResolver.steamMode(for: .steamInstaller) == .installer)
    }

    @Test("steamClient resolves to client surface")
    func steamClient_clientSurface() {
        #expect(UltimatePageResolver.steamMode(for: .steamClient) == .client)
    }

    @Test("all six pages resolve to six distinct production surfaces")
    func allSixPages_sixDistinctSurfaces() {
        let pages = InstallerPage.allCases
        let kinds = pages.map { UltimatePageResolver.contentKind(for: $0) }
        #expect(Set(kinds).count == pages.count)
        #expect(kinds.count == 6)
        // The two Steam pages are distinct surfaces with distinct modes.
        #expect(UltimatePageResolver.contentKind(for: .steamInstaller)
            != UltimatePageResolver.contentKind(for: .steamClient))
    }
}

@MainActor
struct NavigationFunctionalWalkTests {
    let testRuntimeURL = URL(fileURLWithPath: "/usr/lib/wine")
    let testPrefixURL = URL(fileURLWithPath: "/tmp/prefix")

    func makePrefixLayout(root: URL) -> PrefixLayout {
        PrefixLayout(
            root: root,
            driveC: root.appendingPathComponent("drive_c"),
            dosdevices: root.appendingPathComponent("dosdevices"),
            systemReg: root.appendingPathComponent("system.reg"),
            userReg: root.appendingPathComponent("user.reg"),
            windowsSteamCandidates: []
        )
    }

    func makeValidPrefixInspection(root: URL) -> PrefixInspection {
        PrefixInspection(
            prefixURL: root,
            driveCExists: true,
            hasWinePrefix: true,
            hasSteam: false,
            isValid: true
        )
    }

    func makeReadyGameInspection() -> GameInspection {
        GameInspection(
            recipeID: "cloverpit",
            steamPresent: true,
            isWindowsSteam: true,
            manifestPresent: true,
            installDirectoryResolved: true,
            executablePresent: true,
            isReady: true
        )
    }

    /// Coordinator fully provisioned so every page's completion gate opens.
    func makeFullyProvisionedCoordinator() -> UltimateSetupCoordinator {
        let coordinator = UltimateSetupCoordinator()
        coordinator.runtimeURL = testRuntimeURL
        coordinator.runtimeInspection = RuntimeInspection(runtimeID: "test", isUsable: true)
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        coordinator.prefixInspection = makeValidPrefixInspection(root: testPrefixURL)
        coordinator.steamInstallLifecycle = .verifiedComplete
        coordinator.cloverPitInspection = makeReadyGameInspection()
        return coordinator
    }

    @Test("forward walk advances via real send(.next) through all pages")
    func forwardSendWalk_allPages() async {
        let coordinator = makeFullyProvisionedCoordinator()
        coordinator.currentPage = .runtime

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .environment)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .steamInstaller)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .steamClient)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .cloverPit)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .diagnostics)
    }

    @Test("reverse walk returns via real send(.back) through all pages")
    func reverseSendWalk_allPages() async {
        let coordinator = makeFullyProvisionedCoordinator()
        coordinator.currentPage = .diagnostics

        await coordinator.send(.back)
        #expect(coordinator.currentPage == .cloverPit)

        await coordinator.send(.back)
        #expect(coordinator.currentPage == .steamClient)

        await coordinator.send(.back)
        #expect(coordinator.currentPage == .steamInstaller)

        await coordinator.send(.back)
        #expect(coordinator.currentPage == .environment)

        await coordinator.send(.back)
        #expect(coordinator.currentPage == .runtime)
    }

    @Test("diagnostics Back returns to CloverPit via canonical lane")
    func diagnosticsBack_returnsToCloverPit() async {
        let coordinator = makeFullyProvisionedCoordinator()
        coordinator.currentPage = .diagnostics

        await coordinator.send(.back)

        #expect(coordinator.currentPage == .cloverPit)
        #expect(coordinator.lastNavigationResult?.accepted == true)
    }

    @Test("no installer evidence blocks steamInstaller → steamClient")
    func steamInstallerGate_noInstallerEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.currentPage = .steamInstaller
        // No selectedInstaller, no verified lifecycle → page incomplete.

        await coordinator.send(.next)

        #expect(coordinator.currentPage == .steamInstaller)
        #expect(coordinator.lastNavigationResult?.accepted == false)
        #expect(coordinator.lastNavigationResult?.blocker?.code == "page_incomplete")
    }

    @Test("no verified lifecycle blocks steamClient → cloverPit")
    func steamClientGate_noVerifiedLifecycle() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.currentPage = .steamClient
        // steamInstallLifecycle == .absent → page incomplete.

        await coordinator.send(.next)

        #expect(coordinator.currentPage == .steamClient)
        #expect(coordinator.lastNavigationResult?.accepted == false)
        #expect(coordinator.lastNavigationResult?.blocker?.code == "page_incomplete")
    }

    @Test("cleanup failure leaves Steam Client page and records cleanup_required")
    func cleanupFailure_staysOnSteamClient() async {
        let installer = FakeInstallerLifecycleSupervisor()
        installer.setStopAndCleanError(
            InstallerError.terminationFailed("steam.exe not responding")
        )
        let session = FakeGameSessionSupervisor()
        session.isRunning = true
        session.activeSession = GameSession(
            sessionID: UUID(),
            recipeID: "cloverpit",
            runtimeID: "test",
            prefixRoot: testPrefixURL,
            rootPID: 4242,
            startedAt: Date(),
            purpose: .steamSetup
        )
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: session,
            installerSupervisor: installer
        )
        coordinator.currentPage = .steamClient
        coordinator.steamInstallLifecycle = .verifiedComplete

        await coordinator.send(.next)

        #expect(coordinator.currentPage == .steamClient)
        #expect(coordinator.lastNavigationResult?.accepted == false)
        #expect(coordinator.lastNavigationResult?.blocker?.code == "cleanup_required")
    }
}

@MainActor
struct CanonicalPrefixEvidenceTests {
    let testPrefixURL = URL(fileURLWithPath: "/tmp/prefix")

    func makePrefixLayout(root: URL) -> PrefixLayout {
        PrefixLayout(
            root: root,
            driveC: root.appendingPathComponent("drive_c"),
            dosdevices: root.appendingPathComponent("dosdevices"),
            systemReg: root.appendingPathComponent("system.reg"),
            userReg: root.appendingPathComponent("user.reg"),
            windowsSteamCandidates: []
        )
    }

    func makeValidPrefixInspection(root: URL) -> PrefixInspection {
        PrefixInspection(
            prefixURL: root,
            driveCExists: true,
            hasWinePrefix: true,
            hasSteam: false,
            isValid: true
        )
    }

    @Test("same canonical root evidence completes environment")
    func prefixEvidence_sameRoot_completes() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        coordinator.prefixInspection = makeValidPrefixInspection(root: testPrefixURL)

        #expect(coordinator.canonicalPrefixEvidenceValid == true)
        #expect(coordinator.computePageCompletion()[.environment] == true)
    }

    @Test("evidence for a different root is rejected")
    func prefixEvidence_differentRoot_blocked() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        let otherRoot = URL(fileURLWithPath: "/tmp/other-prefix")
        coordinator.prefixInspection = makeValidPrefixInspection(root: otherRoot)

        #expect(coordinator.canonicalPrefixEvidenceValid == false)
        #expect(coordinator.computePageCompletion()[.environment] == false)
    }

    @Test("stale evidence is discarded when the layout root changes")
    func prefixEvidence_stale_blocked() async {
        let coordinator = UltimateSetupCoordinator()
        let rootA = testPrefixURL
        coordinator.prefixLayout = makePrefixLayout(root: rootA)
        coordinator.prefixInspection = makeValidPrefixInspection(root: rootA)
        #expect(coordinator.canonicalPrefixEvidenceValid == true)

        // Layout switches to a different canonical root → stale evidence must go.
        let rootB = URL(fileURLWithPath: "/tmp/prefix-b")
        coordinator.prefixLayout = makePrefixLayout(root: rootB)

        #expect(coordinator.prefixInspection == nil)
        #expect(coordinator.canonicalPrefixEvidenceValid == false)
        #expect(coordinator.computePageCompletion()[.environment] == false)
    }

    @Test("symlink alias of the canonical root follows canonical policy")
    func prefixEvidence_symlinkAlias_canonicalPolicy() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-prefix-evidence-\(UUID().uuidString)")
        let realRoot = base.appendingPathComponent("real")
        let aliasRoot = base.appendingPathComponent("alias")
        try fm.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: aliasRoot, withDestinationURL: realRoot)
        defer { try? fm.removeItem(at: base) }

        let coordinator = UltimateSetupCoordinator()
        // Layout points at the real root; evidence was recorded via the alias.
        coordinator.prefixLayout = makePrefixLayout(root: realRoot)
        coordinator.prefixInspection = makeValidPrefixInspection(root: aliasRoot)

        // Canonical policy: symlink-resolved, standardized comparison → match.
        #expect(coordinator.canonicalPrefixEvidenceValid == true)
    }
}
