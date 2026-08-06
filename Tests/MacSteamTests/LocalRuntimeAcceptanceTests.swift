// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - Helpers

private func makeSession(
    recipeID: String = "cloverpit",
    purpose: SessionPurpose = .game,
    startedAt: Date = Date()
) -> GameSession {
    GameSession(
        sessionID: UUID(),
        recipeID: recipeID,
        runtimeID: "imported_wine",
        prefixRoot: URL(fileURLWithPath: "/tmp/prefix"),
        rootPID: 4242,
        startedAt: startedAt,
        purpose: purpose
    )
}

private func makeSnapshot(
    session: GameSession,
    state: GameSessionState = .runningVisible,
    census: ProcessCensusState = .proven
) -> LocalAcceptanceMachineSnapshot {
    LocalAcceptanceMachineSnapshot(
        sessionID: session.sessionID,
        sessionPurpose: session.purpose,
        recipeID: session.recipeID,
        sessionState: state,
        censusState: census
    )
}

private func makeSatisfiedPrerequisites() -> LocalAcceptancePrerequisites {
    var pre = LocalAcceptancePrerequisites()
    pre.runtimeSourceType = .importedWine
    pre.runtimeRealLoadHealthy = true
    pre.canonicalPrefixBound = true
    pre.steamInstallVerified = true
    pre.cloverpitInstallReady = true
    pre.supervisedGameSessionStarted = true
    return pre
}

// MARK: - Tests

@Suite("LocalRuntimeAcceptanceApp")
@MainActor
struct LocalRuntimeAcceptanceTests {
    /// Controllable clock shared by authority + assertions.
    final class TestClock: @unchecked Sendable {
        var value: TimeInterval
        init(_ value: TimeInterval = 1_000) { self.value = value }
    }

    let session = makeSession()
    let satisfied = makeSatisfiedPrerequisites()

    func makeAuthority(clock: TestClock) -> LocalRuntimeAcceptanceAuthority {
        let authority = LocalRuntimeAcceptanceAuthority { clock.value }
        authority.setPrerequisites(satisfied)
        authority.beginCandidate(for: session, generation: 1)
        return authority
    }

    func advanceStable(_ clock: TestClock, _ authority: LocalRuntimeAcceptanceAuthority) {
        for _ in 0..<60 {
            clock.value += 1
            authority.observe(makeSnapshot(session: session))
        }
    }

    // MARK: Prerequisites

    @Test func prerequisitesFailClosedOnBadWineSource() {
        var pre = makeSatisfiedPrerequisites()
        pre.runtimeSourceType = .systemWine
        #expect(pre.firstBlocker == .runtimeNotImported)
    }

    @Test func prerequisitesFailClosedWhenRealLoadUnhealthy() {
        var pre = makeSatisfiedPrerequisites()
        pre.runtimeRealLoadHealthy = false
        #expect(pre.firstBlocker == .runtimeRealLoadUnhealthy)
    }

    @Test func prerequisitesFailClosedWhenPrefixUnbound() {
        var pre = makeSatisfiedPrerequisites()
        pre.canonicalPrefixBound = false
        #expect(pre.firstBlocker == .canonicalPrefixUnbound)
    }

    @Test func prerequisitesFailClosedWhenSteamUnverified() {
        var pre = makeSatisfiedPrerequisites()
        pre.steamInstallVerified = false
        #expect(pre.firstBlocker == .steamNotVerified)
    }

    @Test func prerequisitesFailClosedWhenCloverPitNotReady() {
        var pre = makeSatisfiedPrerequisites()
        pre.cloverpitInstallReady = false
        #expect(pre.firstBlocker == .cloverpitNotReady)
    }

    @Test func prerequisitesSatisfiedYieldsNoBlocker() {
        #expect(makeSatisfiedPrerequisites().firstBlocker == nil)
    }

    @Test func firstBlockerRespectsGateOrder() {
        var pre = makeSatisfiedPrerequisites()
        pre.runtimeSourceType = .crossover
        pre.canonicalPrefixBound = false
        #expect(pre.firstBlocker == .runtimeNotImported)
    }

    // MARK: Begin candidate gating

    @Test func candidateRefusedWhenPrerequisitesUnmet() {
        var pre = makeSatisfiedPrerequisites()
        pre.runtimeRealLoadHealthy = false
        let clock = TestClock()
        let authority = LocalRuntimeAcceptanceAuthority { clock.value }
        authority.setPrerequisites(pre)
        let result = authority.beginCandidate(for: session, generation: 1)
        #expect(result == .blocked)
        #expect(authority.candidate == nil)
    }

    @Test func candidateBeginsWhenPrerequisitesMet() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        #expect(authority.candidate != nil)
        #expect(authority.state == .inProgress)
    }

    @Test func candidateIsBoundToSession() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        #expect(authority.candidate?.sessionID == session.sessionID)
        #expect(authority.candidate?.recipeID == "cloverpit")
    }

    // MARK: Visibility

    @Test func blockedWhenCensusNotProven() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        authority.observe(makeSnapshot(session: session, census: .incomplete))
        #expect(authority.isBlocked)
        #expect(authority.blocker == .ownershipNotProven)
    }

    @Test func blockedWhenSessionNotGame() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        // Same session identity, but the monitored session stops being a game.
        authority.observe(LocalAcceptanceMachineSnapshot(
            sessionID: session.sessionID,
            sessionPurpose: .steamSetup,
            recipeID: session.recipeID,
            sessionState: .runningVisible,
            censusState: .proven
        ))
        #expect(authority.blocker == .sessionNotGame)
    }

    @Test func blockedWhenRecipeMismatched() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        authority.observe(LocalAcceptanceMachineSnapshot(
            sessionID: session.sessionID,
            sessionPurpose: .game,
            recipeID: "different",
            sessionState: .runningVisible,
            censusState: .proven
        ))
        #expect(authority.blocker == .sessionRecipeMismatch)
    }

    @Test func invalidatedWhenIdentityChanges() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        authority.observe(makeSnapshot(session: session))
        let other = makeSession()
        authority.observe(makeSnapshot(session: other))
        #expect(authority.blocker == .sessionIdentityChanged)
    }

    @Test func invalidatedOnStop() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        authority.observe(makeSnapshot(session: session, state: .stopped))
        #expect(authority.isInvalidated)
        #expect(authority.blocker == .monitorCancelled)
    }

    // MARK: Stability

    @Test func notStableBeforeWindow() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        for _ in 0..<2 {
            clock.value += 5
            authority.observe(makeSnapshot(session: session))
        }
        #expect(authority.state == .awaitingStableVisibility)
        #expect(authority.visibilityStableSeconds < 30)
    }

    @Test func stableAfterFullWindow() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        #expect(authority.state == .awaitingOperatorConfirmation)
        #expect(authority.visibilityStableSeconds >= 30)
    }

    @Test func visibilityLossResetsTimeline() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        for _ in 0..<15 {
            clock.value += 1
            authority.observe(makeSnapshot(session: session))
        }
        authority.observe(makeSnapshot(session: session, state: .runningHidden))
        #expect(authority.visibilityStableSeconds == 0)
        #expect(authority.state == .awaitingStableVisibility)
    }

    @Test func menuConfirmationResetOnVisibilityLoss() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        #expect(authority.confirmMainMenu() == .accepted)
        authority.observe(makeSnapshot(session: session, state: .runningHidden))
        #expect(authority.menuConfirmed == false)
        #expect(authority.confirmMainMenu() == .rejected(.visibilityNotStable))
    }

    // MARK: Operator confirmations

    @Test func mainMenuRefusedBeforeStable() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        #expect(authority.confirmMainMenu() == .rejected(.visibilityNotStable))
    }

    @Test func mainMenuAcceptedWhenStable() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        #expect(authority.confirmMainMenu() == .accepted)
        #expect(authority.menuConfirmed)
    }

    @Test func inputRefusedBeforeMainMenu() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        #expect(authority.confirmInputResponse() == .rejected(.mainMenuUnconfirmed))
    }

    @Test func inputRefusedBeforeStable() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        #expect(authority.confirmInputResponse() == .rejected(.visibilityNotStable))
    }

    @Test func inputAcceptedAfterMainMenu() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        #expect(authority.confirmInputResponse() == .accepted)
        #expect(authority.inputConfirmed)
    }

    // MARK: Cleanup gate

    @Test func completionRejectedWhenNotAtOperatorStage() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        let result = await authority.requireCompletion { .clean }
        #expect(result == .rejected(.visibilityNotStable))
    }

    @Test func completionRejectedWhenMainMenuUnconfirmed() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        let result = await authority.requireCompletion { .clean }
        #expect(result == .rejected(.mainMenuUnconfirmed))
    }

    @Test func completionRejectedWhenInputUnconfirmed() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        let result = await authority.requireCompletion { .clean }
        #expect(result == .rejected(.inputResponseUnconfirmed))
    }

    @Test func completionRejectedOnUncleanCleanup() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        _ = authority.confirmInputResponse()
        let result = await authority.requireCompletion { .incomplete("boom") }
        #expect(result == .rejected(.cleanupIncomplete))
        #expect(authority.isBlocked)
        #expect(authority.cleanupWasClean == false)
    }

    @Test func completionAcceptedOnCleanCleanup() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        _ = authority.confirmInputResponse()
        let result = await authority.requireCompletion { .clean }
        #expect(result == .accepted)
        #expect(authority.isAccepted)
        #expect(authority.cleanupWasClean)
    }

    @Test func completionNeverRerunsCleanup() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        _ = authority.confirmInputResponse()
        var runCount = 0
        let runner: () async -> CleanupResult = {
            runCount += 1
            return .clean
        }
        _ = await authority.requireCompletion(cleanupRunner: runner)
        let second = await authority.requireCompletion(cleanupRunner: runner)
        #expect(second == .alreadyRunning)
        #expect(runCount == 1)
    }

    // MARK: Receipt / security

    @Test func receiptNeverEmitsSessionIdentity() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        let json = authority.currentReceipt.deterministicJSONString
        #expect(!json.contains(session.sessionID.uuidString))
        #expect(!json.contains("4242"))
    }

    @Test func receiptDoesNotEmitRawPath() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        let json = authority.currentReceipt.deterministicJSONString
        #expect(!json.contains("/tmp/prefix"))
    }

    @Test func securityFlagsAlwaysFalse() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        let security = authority.currentReceipt.security
        #expect(security.credentialsAccessed == false)
        #expect(security.rawPIDEmitted == false)
        #expect(security.rawPathEmitted == false)
        #expect(security.rawSessionIDEmitted == false)
        #expect(security.rawWindowIdentityEmitted == false)
    }

    @Test func blockedReceiptHasBoundedBlocker() {
        var pre = makeSatisfiedPrerequisites()
        pre.steamInstallVerified = false
        let clock = TestClock()
        let authority = LocalRuntimeAcceptanceAuthority { clock.value }
        authority.setPrerequisites(pre)
        #expect(authority.currentReceipt.status.blocker == "steam_not_verified")
    }

    @Test func acceptedReceiptIsDeterministic() async {
        let clockA = TestClock()
        let authorityA = makeAuthority(clock: clockA)
        advanceStable(clockA, authorityA)
        _ = authorityA.confirmMainMenu()
        _ = authorityA.confirmInputResponse()
        _ = await authorityA.requireCompletion { .clean }

        let clockB = TestClock(2_000)
        let authorityB = makeAuthority(clock: clockB)
        advanceStable(clockB, authorityB)
        _ = authorityB.confirmMainMenu()
        _ = authorityB.confirmInputResponse()
        _ = await authorityB.requireCompletion { .clean }

        #expect(authorityA.currentReceipt.deterministicJSONString
            == authorityB.currentReceipt.deterministicJSONString)
    }

    // MARK: U1R18-R11-FIX1

    @Test func earnedReceiptRecordsAcceptedStatus() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        _ = authority.confirmInputResponse()
        _ = await authority.requireCompletion { .clean }
        // Receipt is bound to the accepted state, never the cleanup window.
        #expect(authority.currentReceipt.status.state == .accepted)
        #expect(authority.isAccepted)
    }

    @Test func awaitingCleanupNotInvalidatedBySessionStop() async {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        _ = authority.confirmInputResponse()
        // During cleanup the monitored session is expected to leave the running
        // scene; that must not invalidate the authority.
        let result = await authority.requireCompletion {
            authority.observe(makeSnapshot(session: session, state: .stopped))
            return .clean
        }
        #expect(result == .accepted)
        #expect(authority.isAccepted)
    }

    @Test func ownershipProofIndependentlyEarnedAndPersists() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        // A proven census earns ownership before any stable window.
        authority.observe(makeSnapshot(session: session))
        #expect(authority.isOwnershipProven)
        // Losing visibility must NOT revoke the independent ownership proof.
        authority.observe(makeSnapshot(session: session, state: .runningHidden))
        #expect(authority.isOwnershipProven)
        // And a blocked attempt leaves ownership unproven, never inferred from
        // the visible window alone.
        let clock2 = TestClock()
        let authority2 = LocalRuntimeAcceptanceAuthority { clock2.value }
        var pre = makeSatisfiedPrerequisites()
        pre.runtimeRealLoadHealthy = false
        authority2.setPrerequisites(pre)
        authority2.beginCandidate(for: session, generation: 1)
        authority2.observe(makeSnapshot(session: session, state: .runningVisible, census: .proven))
        #expect(authority2.isBlocked)
        #expect(!authority2.isOwnershipProven)
    }

    @Test func ownershipProofSurvivesVisibilityReset() {
        let clock = TestClock()
        let authority = makeAuthority(clock: clock)
        authority.observe(makeSnapshot(session: session))
        advanceStable(clock, authority)
        _ = authority.confirmMainMenu()
        authority.observe(makeSnapshot(session: session, state: .runningHidden))
        // Visibility timeline reset, but the census-derived ownership proof is
        // the authoritative evidence and must persist.
        #expect(authority.menuConfirmed == false)
        #expect(authority.isOwnershipProven)
    }

    @Test func failClosedTerminalStateNeverAutoRecovers() async {
        let clock = TestClock()
        let authority = LocalRuntimeAcceptanceAuthority { clock.value }
        var pre = makeSatisfiedPrerequisites()
        pre.runtimeRealLoadHealthy = false
        authority.setPrerequisites(pre)
        // Prerequisites unmet at begin → blocked; later proving them must not
        // auto-recover a terminal state.
        authority.observe(makeSnapshot(session: session))
        #expect(authority.isBlocked)

        let clock2 = TestClock()
        let authority2 = makeAuthority(clock: clock2)
        advanceStable(clock2, authority2)
        _ = authority2.confirmMainMenu()
        _ = authority2.confirmInputResponse()
        _ = await { await authority2.requireCompletion { .clean } }()
        #expect(authority2.isAccepted)
        // A favourable later observation must not reopen an accepted terminal.
        authority2.observe(makeSnapshot(session: session))
        #expect(authority2.isAccepted)
        #expect(authority2.state == .accepted)
    }
}