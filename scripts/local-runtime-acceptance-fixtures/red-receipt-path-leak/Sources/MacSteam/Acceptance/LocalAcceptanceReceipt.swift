// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum LocalAcceptanceBlocker: String, Codable, Sendable, Equatable, CaseIterable {
    case runtimeNotImported = "runtime_not_imported"
    case runtimeRealLoadUnhealthy = "runtime_real_load_unhealthy"
    case canonicalPrefixUnbound = "canonical_prefix_unbound"
    case steamNotVerified = "steam_not_verified"
    case cloverpitNotReady = "cloverpit_not_ready"
    case sessionNotGame = "session_not_game"
    case sessionRecipeMismatch = "session_recipe_mismatch"
    case sessionIdentityChanged = "session_identity_changed"
    case ownershipNotProven = "ownership_not_proven"
    case targetNotVisible = "target_not_visible"
    case visibilityNotStable = "visibility_not_stable"
    case mainMenuUnconfirmed = "main_menu_unconfirmed"
    case inputResponseUnconfirmed = "input_response_unconfirmed"
    case cleanupIncomplete = "cleanup_incomplete"
    case monitorCancelled = "monitor_cancelled"
}

enum LocalAcceptanceState: String, Sendable, Equatable {
    case notStarted
    case blocked
    case inProgress
    case awaitingStableVisibility
    case awaitingOperatorConfirmation
    case awaitingCleanup
    case accepted
    case invalidated

    var receiptStatus: LocalReceiptStatus {
        switch self {
        case .notStarted, .inProgress, .awaitingStableVisibility,
             .awaitingOperatorConfirmation, .awaitingCleanup: return .inProgress
        case .blocked: return .blocked
        case .accepted: return .accepted
        case .invalidated: return .invalidated
        }
    }
}

enum LocalReceiptStatus: String, Codable, Sendable {
    case blocked
    case inProgress = "in_progress"
    case accepted
    case invalidated
}

struct LocalAcceptanceReceipt: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var prefixPath: String = ""
    var kind: String
    var target: Target
    var status: Status
    var evidence: Evidence
    var security: Security

    struct Target: Codable, Equatable, Sendable {
        var recipeID: String
        var steamAppID: String
    }
    struct Status: Codable, Equatable, Sendable {
        var state: LocalReceiptStatus
        var blocker: String
    }
    struct Evidence: Codable, Equatable, Sendable {
        static let empty = Evidence()
        var importedWineSelected: Bool = false
        var runtimeRealLoadHealthy: Bool = false
        var canonicalPrefixBound: Bool = false
        var steamInstallVerified: Bool = false
        var cloverpitInstallReady: Bool = false
        var supervisedGameSessionStarted: Bool = false
        var ownershipCensusProven: Bool = false
        var targetWindowVisible: Bool = false
        var visibilityStableSeconds: Int = 0
        var mainMenuConfirmedByOperator: Bool = false
        var inputResponseConfirmedByOperator: Bool = false
        var cleanupComplete: Bool = false
    }
    struct Security: Codable, Equatable, Sendable {
        var credentialsAccessed: Bool = false
        var rawPIDEmitted: Bool = false
        var rawPathEmitted: Bool = false
        var rawSessionIDEmitted: Bool = false
        var rawWindowIdentityEmitted: Bool = false
    }

    init(
        state: LocalReceiptStatus,
        blocker: String,
        evidence: Evidence = .empty,
        target: Target = Target(recipeID: "cloverpit", steamAppID: "3314790")
    ) {
        self.schemaVersion = 1
        self.kind = "macsteam_local_runtime_acceptance"
        self.target = target
        self.status = Status(state: state, blocker: blocker)
        self.evidence = evidence
        self.security = Security()
    }

    var deterministicJSON: Data {
        (try? JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "kind": kind,
                "prefixRoot": prefixPath,
                "target": ["recipe_id": target.recipeID,
                           "steam_app_id": target.steamAppID],
                "status": ["state": status.state.rawValue,
                           "blocker": status.blocker],
                "evidence": [
                    "imported_wine_selected": evidence.importedWineSelected,
                    "runtime_real_load_healthy": evidence.runtimeRealLoadHealthy,
                ],
                "security": [
                    "credentials_accessed": security.credentialsAccessed,
                    "raw_pid_emitted": security.rawPIDEmitted,
                ],
            ],
            options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }

    var deterministicJSONString: String {
        String(data: deterministicJSON, encoding: .utf8) ?? "{}"
    }
}