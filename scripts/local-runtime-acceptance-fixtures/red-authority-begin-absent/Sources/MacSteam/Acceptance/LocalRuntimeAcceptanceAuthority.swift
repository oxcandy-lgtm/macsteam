// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture authority (GREEN baseline for the acceptance audit harness).
@MainActor
final class LocalRuntimeAcceptanceAuthority {
    nonisolated static let requiredStabilitySeconds: Int = 30
    private(set) var state: LocalAcceptanceState = .notStarted
    private(set) var blocker: LocalAcceptanceBlocker?

    @discardableResult
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
        return .accepted
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
