// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct LocalAcceptancePrerequisites: Sendable, Equatable {
    var runtimeSourceType: LocalReceiptSourceType = .runtime
    var runtimeRealLoadHealthy: Bool = false
    var canonicalPrefixBound: Bool = false
    var steamInstallVerified: Bool = false
    var cloverpitInstallReady: Bool = false
    var supervisedGameSessionStarted: Bool = false

        if runtimeSourceType != .importedWine { return .runtimeNotImported }
        if !runtimeRealLoadHealthy { return .runtimeRealLoadUnhealthy }
        if !canonicalPrefixBound { return .canonicalPrefixUnbound }
        if !steamInstallVerified { return .steamNotVerified }
        if !cloverpitInstallReady { return .cloverpitNotReady }
        return nil
    }
}

enum LocalReceiptSourceType: String, Sendable, Equatable, Codable {
    case runtime
    case managedWine = "managed-wine"
    case importedWine = "imported-wine"
    case systemWine = "system-wine"
    case crossover
}
