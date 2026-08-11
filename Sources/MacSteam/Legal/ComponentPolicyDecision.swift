// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Separates "external user-provided use" from "redistribution" and "bundling"
/// decisions for third-party components.  A single `DistributionDecision` field
/// conflates these concerns — use `ComponentPolicyDecision` instead.
///
/// Example — Steam Client:
/// ```
/// SteamClient.externalUse       → .allowedUserProvided
/// SteamClient.redistribution    → .forbidden
/// SteamClient.bundling          → .forbidden
/// SteamClient.credentialAccess  → .forbidden
/// ```

// MARK: - Decision types

/// Whether MacSteam may use an externally-provided copy of this component.
enum ExternalUseDecision: String, Codable, Sendable {
    /// User must obtain the component themselves; MacSteam can detect and launch it.
    case allowedUserProvided

    /// Use requires legal review before implementation.
    case reviewRequired

    /// Use is not permitted.
    case forbidden
}

/// Whether MacSteam may redistribute (re-publish) this component's binaries.
enum RedistributionDecision: String, Codable, Sendable {
    /// Redistribution is allowed under license terms.
    case allowed

    /// Redistribution requires conditions to be met (source, SHA, license text, etc.).
    case allowedWithConditions

    /// Redistribution requires legal review.
    case reviewRequired

    /// Redistribution is strictly forbidden.
    case forbidden
}

/// Whether MacSteam may bundle this component inside the application bundle.
enum BundlingDecision: String, Codable, Sendable {
    /// Bundling is allowed.
    case allowed

    /// Bundling is forbidden (component must be installed separately).
    case forbidden
}

/// Whether MacSteam may access credential information for this component.
enum CredentialAccessDecision: String, Codable, Sendable {
    /// Credential access is not permitted.
    case forbidden
}

// MARK: - Policy decision

/// Complete policy decision for a component, disambiguating external use,
/// redistribution, bundling, and credential access.
struct ComponentPolicyDecision: Codable, Sendable, Equatable {
    let componentID: String
    let displayName: String
    let externalUse: ExternalUseDecision
    let redistribution: RedistributionDecision
    let bundling: BundlingDecision
    let credentialAccess: CredentialAccessDecision?

    init(
        componentID: String,
        displayName: String,
        externalUse: ExternalUseDecision,
        redistribution: RedistributionDecision,
        bundling: BundlingDecision,
        credentialAccess: CredentialAccessDecision? = nil
    ) {
        self.componentID = componentID
        self.displayName = displayName
        self.externalUse = externalUse
        self.redistribution = redistribution
        self.bundling = bundling
        self.credentialAccess = credentialAccess
    }
}

// MARK: - Known policies

extension ComponentPolicyDecision {
    /// Steam Client (Valve proprietary)
    static let steamClient = ComponentPolicyDecision(
        componentID: "steam-client",
        displayName: "Steam Client",
        externalUse: .allowedUserProvided,
        redistribution: .forbidden,
        bundling: .forbidden,
        credentialAccess: .forbidden
    )

    /// CloverPit (proprietary game)
    static let cloverPit = ComponentPolicyDecision(
        componentID: "cloverpit",
        displayName: "CloverPit",
        externalUse: .allowedUserProvided,
        redistribution: .forbidden,
        bundling: .forbidden
    )

    /// Wine (LGPL-2.1-or-later)
    static let wine = ComponentPolicyDecision(
        componentID: "wine",
        displayName: "Wine",
        externalUse: .allowedUserProvided,
        redistribution: .allowedWithConditions,
        bundling: .forbidden
    )

    /// DXVK-macOS (Zlib)
    static let dxvkMacOS = ComponentPolicyDecision(
        componentID: "dxvk-macos",
        displayName: "DXVK-macOS",
        externalUse: .allowedUserProvided,
        redistribution: .reviewRequired,
        bundling: .forbidden
    )

    /// MoltenVK (Apache-2.0)
    static let moltenVK = ComponentPolicyDecision(
        componentID: "moltenvk",
        displayName: "MoltenVK",
        externalUse: .allowedUserProvided,
        redistribution: .reviewRequired,
        bundling: .forbidden
    )

    /// D3DMetal / Apple Game Porting Toolkit (Apple proprietary)
    static let d3dMetal = ComponentPolicyDecision(
        componentID: "d3dmetal",
        displayName: "D3DMetal",
        externalUse: .reviewRequired,
        redistribution: .forbidden,
        bundling: .forbidden
    )
}
