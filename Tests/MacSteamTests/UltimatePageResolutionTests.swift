// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import MacsTeamNavigationCore
@testable import MacSteam

// MARK: - Page resolver tests
//
// The root view dispatches pages EXCLUSIVELY through UltimatePageResolver
// (single authority: coordinator.currentPage). These tests pin the resolver
// contract: every page resolves to exactly one content kind, one title, and
// one step number derived from the SAME page value.

struct UltimatePageResolutionTests {
    @Test("all six pages resolve to distinct content kinds")
    func contentKind_isInjectiveOverAllPages() {
        let pages = InstallerPage.allCases
        let kinds = pages.map { UltimatePageResolver.contentKind(for: $0) }
        #expect(Set(kinds).count == pages.count)
        #expect(kinds.count == 6)
    }

    @Test("every page resolves to exactly one content kind")
    func everyPage_hasUniqueContentKind() {
        let kindCounts = Dictionary(
            grouping: InstallerPage.allCases.map { UltimatePageResolver.contentKind(for: $0) },
            by: { $0 }
        )
        for (_, kinds) in kindCounts {
            #expect(kinds.count == 1)
        }
    }

    @Test("title and step number derive from the same page value")
    func titleAndStep_derivedFromSamePage() {
        let pages = InstallerPage.allCases
        for (index, page) in pages.enumerated() {
            // Step number is positional in the canonical page sequence.
            #expect(UltimatePageResolver.stepNumber(for: page) == index + 1)
            // Title is non-empty and unique per page.
            let title = UltimatePageResolver.title(for: page)
            #expect(!title.isEmpty)
            let titles = pages.map { UltimatePageResolver.title(for: $0) }
            #expect(titles.filter { $0 == title }.count == 1)
        }
    }

    @Test("step numbers span exactly 1...6")
    func stepNumbers_spanAllPages() {
        let numbers = InstallerPage.allCases.map { UltimatePageResolver.stepNumber(for: $0) }
        #expect(numbers.sorted() == [1, 2, 3, 4, 5, 6])
    }

    @Test("diagnostics page resolves to diagnostics content and is reachable")
    func diagnosticsPage_resolvesToContent() {
        #expect(UltimatePageResolver.contentKind(for: .diagnostics) == .diagnostics)
        #expect(UltimatePageResolver.title(for: .diagnostics) == "Diagnostics")
        #expect(UltimatePageResolver.stepNumber(for: .diagnostics) == 6)
    }
}

// MARK: - Coordinator navigation authority tests

@MainActor
struct CoordinatorNavigationAuthorityTests {
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

    func makeSession() -> GameSession {
        GameSession(
            sessionID: UUID(),
            recipeID: "cloverpit",
            runtimeID: "test",
            prefixRoot: testPrefixURL,
            rootPID: 4242,
            startedAt: Date(),
            purpose: .steamSetup
        )
    }

    @Test("environment completion requires verification evidence, not mere layout")
    func environmentCompletion_requiresVerificationEvidence() async {
        let coordinator = UltimateSetupCoordinator()
        // Layout resolved but no verification evidence → NOT complete.
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        #expect(coordinator.computePageCompletion()[.environment] == false)

        // Successful verification evidence of the canonical prefix → complete.
        coordinator.prefixInspection = makeValidPrefixInspection(root: testPrefixURL)
        #expect(coordinator.computePageCompletion()[.environment] == true)
    }

    @Test("steamClient completion derives from verified lifecycle")
    func steamClientCompletion_derivesFromLifecycle() async {
        let coordinator = UltimateSetupCoordinator()
        #expect(coordinator.computePageCompletion()[.steamClient] == false)
        coordinator.steamInstallLifecycle = .verifiedComplete
        #expect(coordinator.computePageCompletion()[.steamClient] == true)
    }

    @Test("cloverPit completion derives from canonical detector readiness")
    func cloverPitCompletion_derivesFromDetector() async {
        let coordinator = UltimateSetupCoordinator()
        #expect(coordinator.computePageCompletion()[.cloverPit] == false)
    }

    @Test("diagnostics page is always complete (reachable)")
    func diagnosticsPage_alwaysComplete() async {
        let coordinator = UltimateSetupCoordinator()
        #expect(coordinator.computePageCompletion()[.diagnostics] == true)
    }

    @Test("next from steamClient advances to cloverPit via canonical lane")
    func steamNext_canonicalLane() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: session,
            installerSupervisor: installer
        )
        coordinator.currentPage = .steamClient
        coordinator.steamInstallLifecycle = .verifiedComplete

        await coordinator.send(.next)

        #expect(coordinator.currentPage == .cloverPit)
        #expect(coordinator.lastNavigationResult?.accepted == true)
        #expect(coordinator.lastNavigationResult?.newPage == .cloverPit)
    }

    @Test("next from steamClient is blocked when cleanup fails (page stays)")
    func steamNext_cleanupFailure_blocksAdvance() async {
        let installer = FakeInstallerLifecycleSupervisor()
        installer.setStopAndCleanError(
            InstallerError.terminationFailed("steam.exe not responding")
        )
        let session = FakeGameSessionSupervisor()
        session.isRunning = true
        session.activeSession = makeSession()
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: session,
            installerSupervisor: installer
        )
        coordinator.currentPage = .steamClient
        coordinator.steamInstallLifecycle = .verifiedComplete

        await coordinator.send(.next)

        // Fail-closed: page must NOT advance and a stable blocker is recorded.
        #expect(coordinator.currentPage == .steamClient)
        #expect(coordinator.lastNavigationResult?.accepted == false)
        #expect(coordinator.lastNavigationResult?.blocker?.code == "cleanup_required")
        #expect(installer.stopAndCleanCallCount == 1)
    }

    @Test("back from a mid-flow page returns to previous page")
    func back_returnsToPreviousPage() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: session,
            installerSupervisor: installer
        )
        coordinator.currentPage = .environment

        await coordinator.send(.back)

        #expect(coordinator.currentPage == .runtime)
        #expect(coordinator.lastNavigationResult?.accepted == true)
    }

    @Test("back at first page stays on first page")
    func back_atFirstPage_stays() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.currentPage = .runtime

        await coordinator.send(.back)

        #expect(coordinator.currentPage == .runtime)
    }

    @Test("forward walk follows the canonical page sequence")
    func forwardWalk_followsCanonicalSequence() async {
        let pages = InstallerPage.allCases
        for (index, page) in pages.enumerated() where index > 0 {
            #expect(UltimatePageResolver.stepNumber(for: page) == index + 1)
            let previous = pages[index - 1]
            #expect(UltimatePageResolver.stepNumber(for: previous) == index)
        }
        // The resolver's step numbering IS the navigation sequence.
        #expect(pages.first == .runtime)
        #expect(pages.last == .diagnostics)
    }
}
