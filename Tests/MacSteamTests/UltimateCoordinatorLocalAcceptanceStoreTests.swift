// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - U1R18-R12 coordinator store tests

@Suite("UltimateCoordinatorLocalAcceptanceStore")
@MainActor
struct UltimateCoordinatorLocalAcceptanceStoreTests {
    /// Controllable clock for driving the acceptance authority.
    final class Clock: @unchecked Sendable {
        var value: TimeInterval
        init(_ value: TimeInterval = 1_000) { self.value = value }
    }

    private func makeGatedReceipt() -> LocalAcceptanceReceipt {
        let evidence = LocalAcceptanceReceipt.Evidence(
            importedWineSelected: true, runtimeRealLoadHealthy: true,
            canonicalPrefixBound: true, steamInstallVerified: true,
            cloverpitInstallReady: true, supervisedGameSessionStarted: true,
            ownershipCensusProven: true, targetWindowVisible: true,
            visibilityStableSeconds: 30, mainMenuConfirmedByOperator: true,
            inputResponseConfirmedByOperator: true, cleanupComplete: true
        )
        return LocalAcceptanceReceipt(state: .accepted, blocker: "none", evidence: evidence)
    }

    private func makeTempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-lavi-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession(sessionID: UUID = UUID()) -> GameSession {
        GameSession(
            sessionID: sessionID, recipeID: "cloverpit", runtimeID: "imported_wine",
            prefixRoot: URL(fileURLWithPath: "/tmp/prefix"), rootPID: 4242,
            startedAt: Date(), purpose: .game
        )
    }

    private func makeSnapshot(_ session: GameSession) -> LocalAcceptanceMachineSnapshot {
        LocalAcceptanceMachineSnapshot(
            sessionID: session.sessionID, sessionPurpose: .game,
            recipeID: session.recipeID, sessionState: .runningVisible,
            censusState: .proven
        )
    }

    /// Build an acceptance authority already at the operator phase with both
    /// confirmations given, using the supplied durable persister. Production
    /// wiring of prereqs mirrors `beginLocalAcceptance`.
    private func makeReadyAuthority(
        clock: Clock,
        session: GameSession,
        persister: @escaping (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome
    ) -> LocalRuntimeAcceptanceAuthority {
        let authority = LocalRuntimeAcceptanceAuthority(
            nowProvider: { clock.value },
            receiptPersister: persister
        )
        var pre = LocalAcceptancePrerequisites()
        pre.runtimeSourceType = .importedWine
        pre.runtimeRealLoadHealthy = true
        pre.canonicalPrefixBound = true
        pre.steamInstallVerified = true
        pre.cloverpitInstallReady = true
        pre.supervisedGameSessionStarted = true
        authority.setPrerequisites(pre)
        authority.beginCandidate(for: session, generation: 1)
        for _ in 0..<60 {
            clock.value += 1
            authority.observe(makeSnapshot(session))
        }
        _ = authority.confirmMainMenu()
        _ = authority.confirmInputResponse()
        return authority
    }

    // MARK: Historical load never promotes current state

    @Test func historicalReceiptDoesNotPromoteCurrentRun() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A prior session left an accepted receipt on disk.
        _ = LocalAcceptanceReceiptStore(applicationSupportRoot: root)
            .saveAccepted(makeGatedReceipt())

        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: FakeGameSessionSupervisor(),
            installerSupervisor: FakeInstallerLifecycleSupervisor(),
            receiptStore: LocalAcceptanceReceiptStore(applicationSupportRoot: root)
        )
        // The store surfaces a loaded historical receipt…
        #expect(coordinator.hasSavedLocalAcceptanceReceipt)
        #expect(coordinator.savedLocalAcceptanceReceiptStatus == "accepted")
        // …but it must NOT promote the current run's acceptance state, and must
        // NOT satisfy the current transaction.
        #expect(coordinator.acceptanceState == .notStarted)
        #expect(coordinator.acceptancePresentation.isVisible == false)
        #expect(coordinator.confirmInputResponse() == .rejected(.monitorCancelled))
    }

    @Test func historicalReceiptStatusIsBounded() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = LocalAcceptanceReceiptStore(applicationSupportRoot: root)
            .saveAccepted(makeGatedReceipt())
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: FakeGameSessionSupervisor(),
            installerSupervisor: FakeInstallerLifecycleSupervisor(),
            receiptStore: LocalAcceptanceReceiptStore(applicationSupportRoot: root)
        )
        // Bounded status only — JSON never leaks a raw path/pid/identity.
        let status = coordinator.savedLocalAcceptanceReceiptStatus ?? ""
        #expect(status == "accepted")
        #expect(!status.contains("/tmp"))
        #expect(!status.contains("4242"))
    }

    @Test func noSavedReceiptYieldsNoHistoricalSignal() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: FakeGameSessionSupervisor(),
            installerSupervisor: FakeInstallerLifecycleSupervisor(),
            receiptStore: LocalAcceptanceReceiptStore(applicationSupportRoot: root)
        )
        #expect(coordinator.hasSavedLocalAcceptanceReceipt == false)
        #expect(coordinator.savedLocalAcceptanceReceiptStatus == nil)
    }

    // MARK: Completion persistence path

    @Test func completionPersistsAcceptedReceipt() async {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: FakeGameSessionSupervisor(),
            installerSupervisor: FakeInstallerLifecycleSupervisor(),
            receiptStore: LocalAcceptanceReceiptStore(applicationSupportRoot: root)
        )
        let clock = Clock()
        let session = makeSession()
        let authority = makeReadyAuthority(clock: clock, session: session) { receipt in
            switch LocalAcceptanceReceiptStore(applicationSupportRoot: root).saveAccepted(receipt) {
            case .saved: return .persisted(receipt)
            default: return .failed
            }
        }
        coordinator.installAcceptanceForTesting(authority)

        let result = await coordinator.completeLocalAcceptance()
        #expect(result == .accepted)
        #expect(coordinator.acceptanceState == .accepted)
        #expect(coordinator.hasSavedLocalAcceptanceReceipt)
        #expect(coordinator.savedLocalAcceptanceReceiptStatus == "accepted")
        // The authority survived successful persistence (not discarded).
        #expect(coordinator.acceptanceReceiptJSON.contains("accepted"))
    }

    @Test func completionPersistenceFailureNotPresentedAsAccepted() async {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = UltimateSetupCoordinator(
            sessionSupervisor: FakeGameSessionSupervisor(),
            installerSupervisor: FakeInstallerLifecycleSupervisor(),
            receiptStore: LocalAcceptanceReceiptStore(applicationSupportRoot: root)
        )
        let clock = Clock()
        let authority = makeReadyAuthority(clock: clock, session: makeSession()) { _ in .failed }
        coordinator.installAcceptanceForTesting(authority)

        let result = await coordinator.completeLocalAcceptance()
        #expect(result == .rejected(.receiptPersistenceFailed))
        #expect(coordinator.acceptanceState == .blocked)
        #expect(coordinator.hasSavedLocalAcceptanceReceipt == false)
        #expect(coordinator.acceptancePresentation.title != "Runtime approval complete")
    }
}