// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A machine snapshot reduced by the coordinator from the production supervisor
/// and census. Keeps the authority decision-only and deterministic.
struct LocalAcceptanceMachineSnapshot: Sendable {
    var sessionID: UUID?
    var sessionPurpose: SessionPurpose?
    var recipeID: String?
    var sessionState: GameSessionState
    var censusState: ProcessCensusState
}

/// Bounded output of an operator confirmation / completion action.
enum LocalAcceptanceActionResponse: Sendable, Equatable {
    case accepted
    case rejected(LocalAcceptanceBlocker)
    case alreadyRunning
}

/// Bounded result of the durable persistence step that precedes the accepted
/// state. A failed persistence must never be promoted to acceptance.
enum LocalAcceptancePersistenceOutcome: Sendable, Equatable {
    case persisted(LocalAcceptanceReceipt)
    case failed
}

/// The single candidate a local acceptance transaction is bound to.
struct LocalAcceptanceCandidate: Sendable, Equatable {
    var sessionID: UUID
    var recipeID: String
    var sessionPurpose: SessionPurpose
    var sessionStartGeneration: UInt64
    var acceptanceGeneration: UInt64
    var recipeExpected: String

    init(
        sessionID: UUID,
        recipeID: String,
        sessionPurpose: SessionPurpose,
        sessionStartGeneration: UInt64,
        acceptanceGeneration: UInt64,
        recipeExpected: String
    ) {
        self.sessionID = sessionID
        self.recipeID = recipeID
        self.sessionPurpose = sessionPurpose
        self.sessionStartGeneration = sessionStartGeneration
        self.acceptanceGeneration = acceptanceGeneration
        self.recipeExpected = recipeExpected
    }
}

/// Fail-closed authority owning exactly one local CloverPit runtime acceptance
/// transaction. The coordinator owns the production monitor Task and feeds
/// reduced snapshots here; this type is the single mutation authority for the
/// candidate, session binding, machine evidence, visibility stability, operator
/// confirmations, cleanup, final receipt, and invalidation reason.
@MainActor
final class LocalRuntimeAcceptanceAuthority {
    /// Required continuous (uninterrupted) ownership-bound visible runtime.
    nonisolated static let requiredStabilitySeconds: Int = 30

    nonisolated static let targetRecipeID = "cloverpit"
    nonisolated static let targetSteamAppID = "3314790"

    /// Injectable time authority so tests avoid wall-clock sleeps.
    private let nowProvider: () -> TimeInterval

    private(set) var state: LocalAcceptanceState = .notStarted
    private(set) var blocker: LocalAcceptanceBlocker?
    private(set) var candidate: LocalAcceptanceCandidate?
    private(set) var prerequisites: LocalAcceptancePrerequisites?
    private(set) var earnedReceipt: LocalAcceptanceReceipt?
    private(set) var completionAttempted = false
    private(set) var cleanupWasClean = false
    /// True only after the accepted candidate has been durably persisted and the
    /// persistence step returned a success outcome. Consumed by the coordinator
    /// before it may cancel the production monitor.
    private(set) var receiptPersisted = false

    /// Continuous `runningVisible` start (absolute time). Reset on any loss.
    private var visibleSince: TimeInterval?
    private var operatorMainMenuConfirmed = false
    private var operatorInputConfirmed = false
    private(set) var visibilityStableSeconds: Int = 0

    /// Injectable durable persistence executed exactly once after a clean
    /// cleanup and strictly before the authority may enter the accepted state.
    private let receiptPersister: (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome

    /// Independent ownership evidence. This is bound to the latest census result,
    /// never derived from visibility. It is latched as historical evidence before
    /// cleanup and frozen in the accepted receipt.
    private(set) var ownershipCensusProven = false

    init(
        nowProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        receiptPersister: @escaping (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome
    ) {
        self.nowProvider = nowProvider
        self.receiptPersister = receiptPersister
    }

    // MARK: - Prerequisites

    @discardableResult
    func setPrerequisites(_ machine: LocalAcceptancePrerequisites) -> LocalAcceptanceState {
        prerequisites = machine
        if let blocker = machine.firstBlocker {
            enterBlocked(blocker)
        }
        return state
    }

    // MARK: - Candidate

    /// Binds the candidate to the committed supervised game session. Refuses to
    /// begin on unsatisfied prerequisites.
    @discardableResult
    func beginCandidate(for session: GameSession, generation: UInt64) -> LocalAcceptanceState {
        guard let pre = prerequisites, pre.firstBlocker == nil else {
            return .blocked
        }
        candidate = LocalAcceptanceCandidate(
            sessionID: session.sessionID,
            recipeID: session.recipeID,
            sessionPurpose: session.purpose,
            sessionStartGeneration: UInt64(session.startedAt.timeIntervalSince1970),
            acceptanceGeneration: generation,
            recipeExpected: Self.targetRecipeID
        )
        resetOperationalEvidence()
        state = .inProgress
        return state
    }

    /// Resets any observation-dependent fields. A rejected duplicate launch
    /// never touches an existing valid candidate (caller only invokes begin on
    /// a committed launch).
    private func resetOperationalEvidence() {
        visibleSince = nil
        ownershipCensusProven = false
        operatorMainMenuConfirmed = false
        operatorInputConfirmed = false
        visibilityStableSeconds = 0
        earnedReceipt = nil
        completionAttempted = false
        receiptPersisted = false
    }

    // MARK: - Observation

    func observe(_ snapshot: LocalAcceptanceMachineSnapshot) {
        guard let candidate = candidate else { return }

        // Fail-closed terminality: a bounded terminal state is never mutated by
        // a later (even favourable) snapshot. Only a fresh candidate or an
        // explicit reset may start again.
        switch state {
        case .blocked, .invalidated, .accepted:
            return
        case .awaitingCleanup:
            // During cleanup the session stopping/stopped transitions are the
            // expected result of cleanup, not a monitor cancellation.
            return
        case .notStarted, .inProgress,
             .awaitingStableVisibility, .awaitingOperatorConfirmation:
            break
        }

        guard snapshot.sessionID == candidate.sessionID else {
            invalidate(.sessionIdentityChanged)
            return
        }
        guard snapshot.recipeID == candidate.recipeID else {
            invalidate(.sessionRecipeMismatch)
            return
        }
        guard snapshot.sessionPurpose == .game else {
            invalidate(.sessionNotGame)
            return
        }
        guard snapshot.censusState == .proven else {
            ownershipCensusProven = false
            resetOperationalEvidenceFields()
            enterBlocked(.ownershipNotProven)
            return
        }
        ownershipCensusProven = true

        switch snapshot.sessionState {
        case .runningVisible:
            advanceVisibility()
        case .runningUnknown, .runningHidden:
            loseVisibility()
        case .stopping, .stopped, .failed, .recoveryRequired:
            invalidate(.monitorCancelled)
        case .idle, .launching:
            break
        }
    }

    private func advanceVisibility() {
        if visibleSince == nil {
            visibleSince = nowProvider()
            // Only enter the operator phase once we are in the stable window.
            state = .awaitingStableVisibility
        }
        let now = nowProvider()
        let elapsed = max(0, Int((now - (visibleSince ?? now)) / 1.0))
        visibilityStableSeconds = elapsed
        if elapsed < Self.requiredStabilitySeconds {
            state = .awaitingStableVisibility
        } else {
            state = .awaitingOperatorConfirmation
        }
    }

    private func loseVisibility() {
        visibleSince = nil
        operatorMainMenuConfirmed = false
        operatorInputConfirmed = false
        visibilityStableSeconds = 0
        state = .awaitingStableVisibility
    }

    // MARK: - Operator confirmations

    @discardableResult
    func confirmMainMenu() -> LocalAcceptanceActionResponse {
        guard state == .awaitingOperatorConfirmation else {
            return .rejected(.visibilityNotStable)
        }
        operatorMainMenuConfirmed = true
        return .accepted
    }

    @discardableResult
    func confirmInputResponse() -> LocalAcceptanceActionResponse {
        guard state == .awaitingOperatorConfirmation else {
            return .rejected(.visibilityNotStable)
        }
        guard operatorMainMenuConfirmed else {
            return .rejected(.mainMenuUnconfirmed)
        }
        operatorInputConfirmed = true
        return .accepted
    }

    // MARK: - Completion / cleanup gate

    /// Revalidate prerequisites + stability + both confirmations, then run the
    /// cleanup. Accepts only on a clean cleanup.
    @discardableResult
    func requireCompletion(
        cleanupRunner: @escaping () async -> CleanupResult
    ) async -> LocalAcceptanceActionResponse {
        guard let pre = prerequisites, pre.firstBlocker == nil else {
            return .rejected(prerequisites?.firstBlocker ?? .visibilityNotStable)
        }
        guard completionAttempted == false else {
            return .alreadyRunning
        }
        guard state == .awaitingOperatorConfirmation else {
            return .rejected(pre.firstBlocker ?? .visibilityNotStable)
        }
        guard operatorMainMenuConfirmed else {
            return .rejected(.mainMenuUnconfirmed)
        }
        guard operatorInputConfirmed else {
            return .rejected(.inputResponseUnconfirmed)
        }
        completionAttempted = true
        // Explicit transition into the cleanup phase: the session stopping/
        // stopped transitions during cleanup are expected and must not be read
        // by the observer as a monitor cancellation.
        state = .awaitingCleanup

        let result = await cleanupRunner()
        cleanupWasClean = (result == .clean)
        guard cleanupWasClean else {
            blocker = .cleanupIncomplete
            state = .blocked
            return .rejected(.cleanupIncomplete)
        }
        // The accepted candidate is constructed explicitly as accepted; it is
        // never derived from the live state so it can never silently degrade to
        // in_progress due to ordering.
        let candidate = buildAcceptedReceipt()
        // Durable persistence executes exactly once and MUST succeed before the
        // authority may enter the accepted state. The persisted receipt must be
        // the exact candidate — a persister substituting a different receipt is
        // treated as a bounded persistence failure and cannot accept. A failure
        // leaves the transaction blocked with no earned receipt.
        let outcome = await receiptPersister(candidate)
        guard case .persisted(let persisted) = outcome,
              persisted == candidate else {
            blocker = .receiptPersistenceFailed
            state = .blocked
            earnedReceipt = nil
            receiptPersisted = false
            return .rejected(.receiptPersistenceFailed)
        }
        receiptPersisted = true
        earnedReceipt = persisted
        blocker = nil
        state = .accepted
        return .accepted
    }

    // MARK: - Receipt

    /// Deterministic redacted receipt for current state.
    var currentReceipt: LocalAcceptanceReceipt {
        if let earned = earnedReceipt { return earned }
        let receiptStatus = state.receiptStatus
        return LocalAcceptanceReceipt(
            state: receiptStatus,
            blocker: blocker?.rawValue ?? "none",
            evidence: buildCurrentEvidence()
        )
    }

    private func buildCurrentEvidence() -> LocalAcceptanceReceipt.Evidence {
        let machine = prerequisites ?? LocalAcceptancePrerequisites()
        return LocalAcceptanceReceipt.Evidence(
            importedWineSelected: machine.runtimeSourceType == .importedWine,
            runtimeRealLoadHealthy: machine.runtimeRealLoadHealthy,
            canonicalPrefixBound: machine.canonicalPrefixBound,
            steamInstallVerified: machine.steamInstallVerified,
            cloverpitInstallReady: machine.cloverpitInstallReady,
            supervisedGameSessionStarted: candidate != nil,
            ownershipCensusProven: ownershipCensusProven,
            targetWindowVisible: state == .accepted || state == .awaitingOperatorConfirmation,
            visibilityStableSeconds: visibilityStableSeconds,
            mainMenuConfirmedByOperator: operatorMainMenuConfirmed,
            inputResponseConfirmedByOperator: operatorInputConfirmed,
            cleanupComplete: cleanupWasClean
        )
    }

    private func buildAcceptedReceipt() -> LocalAcceptanceReceipt {
        // Accepted receipts are always emitted as accepted. The accepted status
        // is constructed explicitly rather than derived from the live state so a
        // receipt can never silently degrade to in_progress due to ordering.
        var evidence = buildCurrentEvidence()
        evidence.cleanupComplete = true
        // An accepted receipt means the target window WAS visible across the
        // stability window, so the flag is recorded as proven rather than being
        // derived from the pre-accepted (awaitingCleanup) live state.
        evidence.targetWindowVisible = true
        return LocalAcceptanceReceipt(
            state: .accepted,
            blocker: "none",
            evidence: evidence
        )
    }

    // MARK: - Invalidation

    func invalidate(_ reason: LocalAcceptanceBlocker) {
        state = .invalidated
        blocker = reason
        resetOperationalEvidenceFields()
    }

    private func enterBlocked(_ reason: LocalAcceptanceBlocker) {
        state = .blocked
        blocker = reason
        resetOperationalEvidenceFields()
    }

    private func resetOperationalEvidenceFields() {
        visibleSince = nil
        ownershipCensusProven = false
        operatorMainMenuConfirmed = false
        operatorInputConfirmed = false
        visibilityStableSeconds = 0
    }

    // read-only surface for coordinator / view
    var isAccepted: Bool { state == .accepted }
    var isInvalidated: Bool { state == .invalidated }
    var isBlocked: Bool { state == .blocked }
    var menuConfirmed: Bool { operatorMainMenuConfirmed }
    var inputConfirmed: Bool { operatorInputConfirmed }
    var isOwnershipProven: Bool { ownershipCensusProven }
    var hasPersistedReceipt: Bool { receiptPersisted }
}