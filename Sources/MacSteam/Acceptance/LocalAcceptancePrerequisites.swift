// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Exact prerequisite contract a candidate must satisfy before it may begin.
///
/// Every gate is independently checked. System Wine discovery is not enough and
/// CrossOver is not an accepted substitute. A stale inspection must not satisfy
/// the candidate — the coordinator reconstructs these from **current** derived
/// state at launch time.
struct LocalAcceptancePrerequisites: Sendable, Equatable {
    var runtimeSourceType: LocalReceiptSourceType = .runtime
    var runtimeRealLoadHealthy: Bool = false

    var canonicalPrefixBound: Bool = false
    var steamInstallVerified: Bool = false
    var cloverpitInstallReady: Bool = false

    var supervisedGameSessionStarted: Bool = false

    init() {}

    init(
        runtimeSourceType: LocalReceiptSourceType,
        runtimeRealLoadHealthy: Bool,
        canonicalPrefixBound: Bool,
        steamInstallVerified: Bool,
        cloverpitInstallReady: Bool,
        supervisedGameSessionStarted: Bool = false
    ) {
        self.runtimeSourceType = runtimeSourceType
        self.runtimeRealLoadHealthy = runtimeRealLoadHealthy
        self.canonicalPrefixBound = canonicalPrefixBound
        self.steamInstallVerified = steamInstallVerified
        self.cloverpitInstallReady = cloverpitInstallReady
        self.supervisedGameSessionStarted = supervisedGameSessionStarted
    }

    /// The first unsatisfied blocker, or nil when every prerequisite holds.
    var firstBlocker: LocalAcceptanceBlocker? {
        if runtimeSourceType != .importedWine {
            return .runtimeNotImported
        }
        if !runtimeRealLoadHealthy {
            return .runtimeRealLoadUnhealthy
        }
        if !canonicalPrefixBound {
            return .canonicalPrefixUnbound
        }
        if !steamInstallVerified {
            return .steamNotVerified
        }
        if !cloverpitInstallReady {
            return .cloverpitNotReady
        }
        return nil
    }

    func satisfyReceipt(_ evidence: inout LocalAcceptanceReceipt.Evidence) {
        evidence.runtimeRealLoadHealthy = runtimeRealLoadHealthy
        evidence.canonicalPrefixBound = canonicalPrefixBound
        evidence.steamInstallVerified = steamInstallVerified
        evidence.cloverpitInstallReady = cloverpitInstallReady
    }
}

/// Bounded runtime-source classification for the acceptance prerequisite —
/// mirrors `RuntimeType` but only admits imported Wine as accepted.
enum LocalReceiptSourceType: String, Sendable, Equatable, Codable {
    case runtime
    case managedWine = "managed-wine"
    case importedWine = "imported-wine"
    case systemWine = "system-wine"
    case crossover

    init(runtimeType: RuntimeType?) {
        switch runtimeType {
        case .managedWine: self = .managedWine
        case .importedWine: self = .importedWine
        case .systemWine: self = .systemWine
        case .crossover: self = .crossover
        case nil: self = .runtime
        }
    }
}