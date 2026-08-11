// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bounded machine-evidence and operator-confirmation codes that drive a
/// local CloverPit runtime acceptance transaction.
///
/// No raw `Error.localizedDescription` is ever encoded into a receipt; every
/// blocker is a bounded symbol a consumer can map to deterministic UI.
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
    case receiptPersistenceFailed = "receipt_persistence_failed"
}

/// Top-level state of a single acceptance candidate.
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
             .awaitingOperatorConfirmation, .awaitingCleanup:
            return .inProgress
        case .blocked:
            return .blocked
        case .accepted:
            return .accepted
        case .invalidated:
            return .invalidated
        }
    }
}

/// Schema `status.state` enum for a local acceptance receipt.
enum LocalReceiptStatus: String, Codable, Sendable {
    case blocked
    case inProgress = "in_progress"
    case accepted
    case invalidated
}

/// Deterministic, redacted acceptance receipt matching
/// `Contracts/local-runtime-acceptance.schema.json`.
///
/// Contains only bounded booleans/ints plus bounded enums. It never carries
/// PIDs, PPIDs, UUIDs, absolute paths, usernames, account names, window
/// identities, argv, or raw error text.
struct LocalAcceptanceReceipt: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var kind: String

    var target: Target
    var status: Status
    var evidence: Evidence
    var security: Security

    struct Target: Codable, Equatable, Sendable {
        var recipeID: String
        var steamAppID: String

        static let canonical = Target(recipeID: "cloverpit", steamAppID: "3314790")

        init(recipeID: String, steamAppID: String) {
            self.recipeID = recipeID
            self.steamAppID = steamAppID
        }

        private enum CodingKeys: String, CodingKey {
            case recipeID = "recipe_id"
            case steamAppID = "steam_app_id"
        }
    }

    struct Status: Codable, Equatable, Sendable {
        var state: LocalReceiptStatus
        var blocker: String

        init(state: LocalReceiptStatus, blocker: String) {
            self.state = state
            self.blocker = blocker
        }
    }

    struct Evidence: Codable, Equatable, Sendable {
        var importedWineSelected: Bool
        var runtimeRealLoadHealthy: Bool
        var canonicalPrefixBound: Bool
        var steamInstallVerified: Bool
        var cloverpitInstallReady: Bool
        var supervisedGameSessionStarted: Bool
        var ownershipCensusProven: Bool
        var targetWindowVisible: Bool
        var visibilityStableSeconds: Int
        var mainMenuConfirmedByOperator: Bool
        var inputResponseConfirmedByOperator: Bool
        var cleanupComplete: Bool

        static let empty = Evidence()

        init(
            importedWineSelected: Bool = false,
            runtimeRealLoadHealthy: Bool = false,
            canonicalPrefixBound: Bool = false,
            steamInstallVerified: Bool = false,
            cloverpitInstallReady: Bool = false,
            supervisedGameSessionStarted: Bool = false,
            ownershipCensusProven: Bool = false,
            targetWindowVisible: Bool = false,
            visibilityStableSeconds: Int = 0,
            mainMenuConfirmedByOperator: Bool = false,
            inputResponseConfirmedByOperator: Bool = false,
            cleanupComplete: Bool = false
        ) {
            self.importedWineSelected = importedWineSelected
            self.runtimeRealLoadHealthy = runtimeRealLoadHealthy
            self.canonicalPrefixBound = canonicalPrefixBound
            self.steamInstallVerified = steamInstallVerified
            self.cloverpitInstallReady = cloverpitInstallReady
            self.supervisedGameSessionStarted = supervisedGameSessionStarted
            self.ownershipCensusProven = ownershipCensusProven
            self.targetWindowVisible = targetWindowVisible
            self.visibilityStableSeconds = visibilityStableSeconds
            self.mainMenuConfirmedByOperator = mainMenuConfirmedByOperator
            self.inputResponseConfirmedByOperator = inputResponseConfirmedByOperator
            self.cleanupComplete = cleanupComplete
        }

        mutating func merge(_ machine: LocalAcceptancePrerequisites) {
            self.runtimeRealLoadHealthy = machine.runtimeRealLoadHealthy
            self.canonicalPrefixBound = machine.canonicalPrefixBound
            self.steamInstallVerified = machine.steamInstallVerified
            self.cloverpitInstallReady = machine.cloverpitInstallReady
        }

        private enum CodingKeys: String, CodingKey {
            case importedWineSelected = "imported_wine_selected"
            case runtimeRealLoadHealthy = "runtime_real_load_healthy"
            case canonicalPrefixBound = "canonical_prefix_bound"
            case steamInstallVerified = "steam_install_verified"
            case cloverpitInstallReady = "cloverpit_install_ready"
            case supervisedGameSessionStarted = "supervised_game_session_started"
            case ownershipCensusProven = "ownership_census_proven"
            case targetWindowVisible = "target_window_visible"
            case visibilityStableSeconds = "visibility_stable_seconds"
            case mainMenuConfirmedByOperator = "main_menu_confirmed_by_operator"
            case inputResponseConfirmedByOperator = "input_response_confirmed_by_operator"
            case cleanupComplete = "cleanup_complete"
        }
    }

    struct Security: Codable, Equatable, Sendable {
        var credentialsAccessed: Bool
        var rawPIDEmitted: Bool
        var rawPathEmitted: Bool
        var rawSessionIDEmitted: Bool
        var rawWindowIdentityEmitted: Bool

        init() {
            self.credentialsAccessed = false
            self.rawPIDEmitted = false
            self.rawPathEmitted = false
            self.rawSessionIDEmitted = false
            self.rawWindowIdentityEmitted = false
        }

        private enum CodingKeys: String, CodingKey {
            case credentialsAccessed = "credentials_accessed"
            case rawPIDEmitted = "raw_pid_emitted"
            case rawPathEmitted = "raw_path_emitted"
            case rawSessionIDEmitted = "raw_session_id_emitted"
            case rawWindowIdentityEmitted = "raw_window_identity_emitted"
        }
    }

    init(
        state: LocalReceiptStatus,
        blocker: String,
        evidence: Evidence = .empty,
        target: Target = .canonical
    ) {
        self.schemaVersion = 1
        self.kind = "macsteam_local_runtime_acceptance"
        self.target = target
        self.status = Status(state: state, blocker: blocker)
        self.evidence = evidence
        self.security = Security()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case target
        case status
        case evidence
        case security
    }
}

extension LocalAcceptanceReceipt {
    /// Deterministic sorted-key JSON produced from live fields. Keys appear in
    /// sorted order regardless of declaration order, so two receipts with equal
    /// fields yield byte-identical output for test comparison and UI copy.
    var deterministicJSON: Data {
        let root: [String: Any] = [
            "schema_version": 1,
            "kind": "macsteam_local_runtime_acceptance",
            "target": [
                "recipe_id": target.recipeID,
                "steam_app_id": target.steamAppID,
            ],
            "status": [
                "state": status.state.rawValue,
                "blocker": status.blocker,
            ],
            "evidence": [
                "imported_wine_selected": evidence.importedWineSelected,
                "runtime_real_load_healthy": evidence.runtimeRealLoadHealthy,
                "canonical_prefix_bound": evidence.canonicalPrefixBound,
                "steam_install_verified": evidence.steamInstallVerified,
                "cloverpit_install_ready": evidence.cloverpitInstallReady,
                "supervised_game_session_started": evidence.supervisedGameSessionStarted,
                "ownership_census_proven": evidence.ownershipCensusProven,
                "target_window_visible": evidence.targetWindowVisible,
                "visibility_stable_seconds": evidence.visibilityStableSeconds,
                "main_menu_confirmed_by_operator": evidence.mainMenuConfirmedByOperator,
                "input_response_confirmed_by_operator": evidence.inputResponseConfirmedByOperator,
                "cleanup_complete": evidence.cleanupComplete,
            ],
            "security": [
                "credentials_accessed": security.credentialsAccessed,
                "raw_pid_emitted": security.rawPIDEmitted,
                "raw_path_emitted": security.rawPathEmitted,
                "raw_session_id_emitted": security.rawSessionIDEmitted,
                "raw_window_identity_emitted": security.rawWindowIdentityEmitted,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    /// Deterministic, redacted JSON string for in-memory copy/export.
    var deterministicJSONString: String {
        String(data: deterministicJSON, encoding: .utf8) ?? "{}"
    }
}