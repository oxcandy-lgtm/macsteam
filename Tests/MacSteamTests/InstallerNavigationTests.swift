// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import MacsTeamNavigationCore
@testable import MacSteam

// MARK: - Reducer tests

/// Tests the `InstallerNavigationReducer` state machine directly.
///
/// The reducer is a public actor in `MacsTeamNavigationCore`; it owns a
/// mutable page + completion state and enforces the navigation contract:
/// `next` requires the current page complete, no active operation, and no
/// pending cleanup; `back` only requires no active operation/cleanup.
struct InstallerNavigationReducerTests {
    func makeReducer() -> InstallerNavigationReducer {
        InstallerNavigationReducer(initialPage: .runtime)
    }

    @Test("next advances runtime → environment when complete")
    func next_runtimeToEnvironment() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        let result = await reducer.send(intent: .next)
        #expect(result.accepted)
        #expect(result.newPage == .environment)
    }

    @Test("next advances environment → steamInstaller")
    func next_environmentToSteamInstaller() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        _ = await reducer.send(intent: .next) // → environment
        await reducer.setPageComplete(.environment)
        let result = await reducer.send(intent: .next)
        #expect(result.accepted)
        #expect(result.newPage == .steamInstaller)
    }

    @Test("next advances steamInstaller → steamClient")
    func next_steamInstallerToSteamClient() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        _ = await reducer.send(intent: .next) // → environment
        await reducer.setPageComplete(.environment)
        _ = await reducer.send(intent: .next) // → steamInstaller
        await reducer.setPageComplete(.steamInstaller)
        let result = await reducer.send(intent: .next)
        #expect(result.accepted)
        #expect(result.newPage == .steamClient)
    }

    @Test("next advances steamClient → cloverPit")
    func next_steamClientToCloverPit() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        _ = await reducer.send(intent: .next) // → environment
        await reducer.setPageComplete(.environment)
        _ = await reducer.send(intent: .next) // → steamInstaller
        await reducer.setPageComplete(.steamInstaller)
        _ = await reducer.send(intent: .next) // → steamClient
        await reducer.setPageComplete(.steamClient)
        let result = await reducer.send(intent: .next)
        #expect(result.accepted)
        #expect(result.newPage == .cloverPit)
    }

    @Test("next advances cloverPit → diagnostics")
    func next_cloverPitToDiagnostics() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        _ = await reducer.send(intent: .next) // → environment
        await reducer.setPageComplete(.environment)
        _ = await reducer.send(intent: .next) // → steamInstaller
        await reducer.setPageComplete(.steamInstaller)
        _ = await reducer.send(intent: .next) // → steamClient
        await reducer.setPageComplete(.steamClient)
        _ = await reducer.send(intent: .next) // → cloverPit
        await reducer.setPageComplete(.cloverPit)
        let result = await reducer.send(intent: .next)
        #expect(result.accepted)
        #expect(result.newPage == .diagnostics)
    }

    @Test("next from last page stays")
    func next_atLastPage_stays() async {
        let reducer = makeReducer()
        for page in [InstallerPage.runtime, .environment, .steamInstaller, .steamClient, .cloverPit, .diagnostics] {
            await reducer.setPageComplete(page)
            _ = await reducer.send(intent: .next)
        }
        let result = await reducer.send(intent: .next)
        #expect(result.accepted)
        #expect(result.newPage == nil)
    }

    @Test("back returns to previous page")
    func back_returnsToPrevious() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        _ = await reducer.send(intent: .next) // → environment
        let result = await reducer.send(intent: .back)
        #expect(result.accepted)
        #expect(result.newPage == .runtime)
    }

    @Test("back at first page stays")
    func back_atFirstPage_stays() async {
        let reducer = makeReducer()
        let result = await reducer.send(intent: .back)
        #expect(result.accepted)
        #expect(result.newPage == nil)
    }

    @Test("next rejected when page incomplete")
    func next_rejectedWhenIncomplete() async {
        let reducer = makeReducer()
        let result = await reducer.send(intent: .next)
        #expect(!result.accepted)
        #expect(result.blocker?.code == "page_incomplete")
    }

    @Test("next rejected when active operation")
    func next_rejectedWhenActiveOperation() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        await reducer.setActiveOperation(true)
        let result = await reducer.send(intent: .next)
        #expect(!result.accepted)
        #expect(result.blocker?.code == "active_operation")
    }

    @Test("next rejected when cleanup required")
    func next_rejectedWhenCleanupRequired() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        await reducer.setCleanupRequired(true)
        let result = await reducer.send(intent: .next)
        #expect(!result.accepted)
        #expect(result.blocker?.code == "cleanup_required")
    }

    @Test("back rejected when active operation")
    func back_rejectedWhenActiveOperation() async {
        let reducer = makeReducer()
        await reducer.setPageComplete(.runtime)
        _ = await reducer.send(intent: .next) // → environment
        await reducer.setActiveOperation(true)
        let result = await reducer.send(intent: .back)
        #expect(!result.accepted)
        #expect(result.blocker?.code == "active_operation")
    }

    @Test("stopAndClean clears active operation")
    func stopAndClean_clearsActiveOperation() async {
        let reducer = makeReducer()
        await reducer.setActiveOperation(true)
        let result = await reducer.send(intent: .stopAndClean)
        #expect(result.accepted)
    }
}

// MARK: - Coordinator navigation tests

/// Tests `UltimateSetupCoordinator`'s navigation integration: the coordinator
/// derives per-page completion from real state (`runtimeURL` + inspection,
/// `prefixLayout`, `steamInstallLifecycle`, `cloverPitInspection`), feeds it
/// into the reducer via `send(_:)`, and applies resulting transitions to
/// `currentPage`.
///
/// Fakes: `FakeGameSessionSupervisor` / `FakeInstallerLifecycleSupervisor`
/// are defined in UltimateCleanupOrchestrationTests.swift and reused here
/// (same test module) so no real process supervision is touched.
@MainActor
struct CoordinatorNavigationTests {
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

    // Helper: create a coordinator with fakes (same pattern as
    // UltimateCleanupOrchestrationTests).
    func makeCoordinator(
        session: FakeGameSessionSupervisor = FakeGameSessionSupervisor(),
        installer: FakeInstallerLifecycleSupervisor = FakeInstallerLifecycleSupervisor()
    ) -> UltimateSetupCoordinator {
        UltimateSetupCoordinator(
            sessionSupervisor: session,
            installerSupervisor: installer
        )
    }

    @Test("runtime completion reflects real runtime state")
    func runtimeCompletion_realState() async {
        let coordinator = makeCoordinator()
        // No runtime selected → runtime page is incomplete.
        #expect(coordinator.computePageCompletion()[.runtime] == false)

        // Selecting a usable runtime flips completion to true.
        coordinator.runtimeURL = testRuntimeURL
        coordinator.runtimeInspection = RuntimeInspection(runtimeID: "test", isUsable: true)
        #expect(coordinator.computePageCompletion()[.runtime] == true)

        // Environment completion derives from VERIFICATION EVIDENCE of the
        // canonical prefix — mere layout resolution is not sufficient.
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        #expect(coordinator.computePageCompletion()[.environment] == false)
        coordinator.prefixInspection = PrefixInspection(
            prefixURL: testPrefixURL,
            driveCExists: true,
            hasWinePrefix: true,
            hasSteam: false,
            isValid: true
        )
        #expect(coordinator.computePageCompletion()[.environment] == true)
    }

    @Test("steamClient completion is not fixed false")
    func steamClientCompletion_notFixedFalse() async {
        // The completion map must derive from steamInstallLifecycle, not be
        // hardcoded. With an absent lifecycle steamClient is incomplete…
        let coordinator = makeCoordinator()
        #expect(coordinator.computePageCompletion()[.steamClient] != nil)
        #expect(coordinator.computePageCompletion()[.steamClient] == false)

        // …and it flips to complete once the lifecycle is verified.
        coordinator.steamInstallLifecycle = .verifiedComplete
        #expect(coordinator.computePageCompletion()[.steamClient] == true)
    }

    @Test("cloverPit completion is not fixed false")
    func cloverPitCompletion_notFixedFalse() async {
        // Derives from cloverPitInspection — not hardcoded false.
        let coordinator = makeCoordinator()
        #expect(coordinator.computePageCompletion()[.cloverPit] != nil)
        #expect(coordinator.computePageCompletion()[.cloverPit] == false)

        coordinator.cloverPitInspection = GameInspection(
            recipeID: "cloverpit",
            steamPresent: true,
            isWindowsSteam: true,
            manifestPresent: true,
            installDirectoryResolved: true,
            executablePresent: true,
            isReady: true
        )
        #expect(coordinator.computePageCompletion()[.cloverPit] == true)
    }

    @Test("diagnostics always complete")
    func diagnosticsAlwaysComplete() async {
        let coordinator = makeCoordinator()
        #expect(coordinator.computePageCompletion()[.diagnostics] == true)
    }

    @Test("back with no active operation transitions")
    func back_noActiveOperation_transitions() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // Drive navigation through the coordinator: usable runtime → next
        // advances to .environment.
        coordinator.runtimeURL = testRuntimeURL
        coordinator.runtimeInspection = RuntimeInspection(runtimeID: "test", isUsable: true)
        await coordinator.send(.next)
        #expect(coordinator.currentPage == .environment)

        // Back with no active operation returns to the previous page.
        await coordinator.send(.back)
        #expect(coordinator.currentPage == .runtime)
    }

    @Test("next rejected when runtime incomplete")
    func next_rejectedWhenRuntimeIncomplete() async {
        let coordinator = makeCoordinator()
        coordinator.currentPage = .runtime
        await coordinator.send(.next)
        #expect(coordinator.lastNavigationResult?.accepted == false)
        #expect(coordinator.lastNavigationResult?.blocker?.code == "page_incomplete")
    }
}
