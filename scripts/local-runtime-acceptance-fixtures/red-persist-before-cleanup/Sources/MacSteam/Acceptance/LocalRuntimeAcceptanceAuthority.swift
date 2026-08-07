// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture authority (GREEN baseline for the acceptance audit harness).
@MainActor
final class LocalRuntimeAcceptanceAuthority {
    nonisolated static let requiredStabilitySeconds: Int = 30
    private(set) var state: LocalAcceptanceState = .notStarted
    private(set) var blocker: LocalAcceptanceBlocker?
    private(set) var earnedReceipt: LocalAcceptanceReceipt?
    private(set) var ownershipCensusProven = false

    @discardableResult
    func beginCandidate(for session: GameSession, generation: UInt64) -> LocalAcceptanceState {
        state = .inProgress
        return state
    }

    func observe(_ snapshot: LocalAcceptanceMachineSnapshot) {
    }

    @discardableResult

    @discardableResult
    func requireCompletion(
        cleanupRunner: @escaping () async -> CleanupResult
    ) async -> LocalAcceptanceActionResponse {
        let candidate = buildAcceptedReceipt()
        let outcome = await receiptPersister(candidate)
        let result = await cleanupRunner()
        guard result == .clean else { return .rejected(.cleanupIncomplete) }
        guard case .persisted = outcome else { return .rejected(.receiptPersistenceFailed) }
        state = .accepted
        earnedReceipt = candidate
        return .accepted
    }


    private func buildAcceptedReceipt() -> LocalAcceptanceReceipt {
        LocalAcceptanceReceipt(
            state: .accepted,
            blocker: "none",
            evidence: .empty
        )
    }

    private func receiptPersister(
        _ receipt: LocalAcceptanceReceipt
    ) async -> LocalAcceptancePersistenceOutcome {
        .persisted(receipt)
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