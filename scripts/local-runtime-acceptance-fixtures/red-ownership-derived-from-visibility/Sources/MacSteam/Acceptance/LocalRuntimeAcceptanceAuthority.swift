// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// FAILING fixture: ownership is claimed from mere window visibility rather
/// than an independent census-derived boolean (regression of FIX1 ownership
/// independence).
@MainActor
final class LocalRuntimeAcceptanceAuthority {
    nonisolated static let requiredStabilitySeconds: Int = 30
    private(set) var state: LocalAcceptanceState = .notStarted
    private(set) var blocker: LocalAcceptanceBlocker?
    private var visibleSince: Date?

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
        await cleanupRunner()
        state = .accepted
        let _ = buildAcceptedReceipt()
        return .accepted
    }

    private func buildAcceptedReceipt() -> LocalAcceptanceReceipt {
        LocalAcceptanceReceipt(
            state: .accepted,
            blocker: "none",
            // FIX1: ownership must NOT be derived from mere visibility.
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
    var sessionState: GameSessionState
    var censusState: ProcessCensusState
}

enum LocalAcceptanceActionResponse: Sendable, Equatable {
    case accepted
    case rejected(LocalAcceptanceBlocker)
    case alreadyRunning
}