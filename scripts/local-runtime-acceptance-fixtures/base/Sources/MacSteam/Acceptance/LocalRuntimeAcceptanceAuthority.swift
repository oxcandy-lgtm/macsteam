// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture authority (GREEN baseline for the acceptance audit harness).
/// The durable persister is a required init parameter (no success-default) and
/// the persisted receipt must be the exact candidate before acceptance.
@MainActor
final class LocalRuntimeAcceptanceAuthority {
    nonisolated static let requiredStabilitySeconds: Int = 30
    private(set) var state: LocalAcceptanceState = .notStarted
    private(set) var blocker: LocalAcceptanceBlocker?
    private(set) var earnedReceipt: LocalAcceptanceReceipt?
    private(set) var ownershipCensusProven = false

    private let receiptPersister: (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome

    init(
        nowProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        receiptPersister: @escaping (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome
    ) {
        self.receiptPersister = receiptPersister
    }

    @discardableResult
    func beginCandidate(for session: GameSession, generation: UInt64) -> LocalAcceptanceState {
        state = .inProgress
        return state
    }

    func observe(_ snapshot: LocalAcceptanceMachineSnapshot) {
    }

    @discardableResult
    func requireCompletion(
        cleanupRunner: @escaping () async -> CleanupResult
    ) async -> LocalAcceptanceActionResponse {
        let result = await cleanupRunner()
        guard result == .clean else {
            blocker = .cleanupIncomplete
            state = .blocked
            return .rejected(.cleanupIncomplete)
        }
        // The accepted candidate is constructed, then durably persisted exactly
        // once AFTER clean cleanup and STRICTLY BEFORE the accepted state. The
        // persisted receipt must be the exact candidate (identity checked).
        let candidate = buildAcceptedReceipt()
        let outcome = await receiptPersister(candidate)
        guard case .persisted(let persisted) = outcome,
              persisted == candidate else {
            blocker = .receiptPersistenceFailed
            state = .blocked
            return .rejected(.receiptPersistenceFailed)
        }
        state = .accepted
        earnedReceipt = persisted
        return .accepted
    }

    private func buildAcceptedReceipt() -> LocalAcceptanceReceipt {
        LocalAcceptanceReceipt(
            state: .accepted,
            blocker: "none",
            evidence: .empty
        )
    }

    var currentReceipt: LocalAcceptanceReceipt {
        LocalAcceptanceReceipt(
            state: .accepted,
            blocker: "none",
            evidence: .empty
        )
    }
}

struct LocalAcceptanceMachineSnapshot: Sendable {
    var sessionID: UUID?
    var sessionPurpose: SessionPurpose?
    var recipeID: String?
    var sessionState: GameSessionState
    var censusState: ProcessCensusState
}

enum LocalAcceptanceActionResponse: Sendable, Equatable {
    case accepted
    case rejected(LocalAcceptanceBlocker)
    case alreadyRunning
}

enum LocalAcceptancePersistenceOutcome: Sendable, Equatable {
    case persisted(LocalAcceptanceReceipt)
    case failed
}