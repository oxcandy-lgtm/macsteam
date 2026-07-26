// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A gate that checks whether a component is allowed to be distributed,
/// referenced, or bundled based on its license artifact and project policy.
///
/// Every component loaded by MacSteam must pass through `DistributionGate`.
public enum DistributionGate {

    // MARK: - Component policy IDs

    public enum ComponentID: String, CaseIterable, Codable, Sendable {
        case wine
        case dxvkMacOS = "dxvk-macos"
        case moltenvk = "moltenvk"
        case steamClient = "steam-client"
        case d3dmetal = "d3dmetal"
    }

    // MARK: - Distribution result

    public enum DistributionDecision: Sendable, Equatable {
        /// Component may be distributed under its license terms.
        case allowed
        /// Component may not be distributed at this time.
        case forbidden(reason: String)
        /// Needs human review before a decision can be made.
        case reviewRequired(details: String)
    }

    // MARK: - Public API

    /// Evaluate whether a component is eligible for distribution or use.
    /// - Parameters:
    ///   - componentID: The component identifier from component-lock.json.
    ///   - bundled: Whether the component is bundled into the app bundle.
    ///   - licenseSPDX: The SPDX identifier of the component's license.
    ///   - manifestHash: The SHA-256 of the runtime artifact manifest (if available).
    /// - Returns: A `DistributionDecision`.
    public static func evaluate(
        componentID: ComponentID,
        bundled: Bool,
        licenseSPDX: String,
        manifestHash: String? = nil
    ) -> DistributionDecision {
        // Proprietary components are never bundled.
        if bundled {
            switch componentID {
            case .steamClient, .d3dmetal:
                return .forbidden(reason: "\(componentID.rawValue) is proprietary and must not be bundled")
            default:
                break
            }
        }

        // Redistribution requires a manifest hash.
        if manifestHash == nil || manifestHash?.count != 64 {
            return .reviewRequired(details: "Missing or invalid artifact manifest SHA-256")
        }

        switch componentID {
        case .wine:
            return evaluateWine(licenseSPDX: licenseSPDX, bundled: bundled)
        case .dxvkMacOS:
            return evaluateDXVK(licenseSPDX: licenseSPDX, bundled: bundled)
        case .moltenvk:
            return evaluateMoltenVK(licenseSPDX: licenseSPDX, bundled: bundled)
        case .steamClient:
            return .forbidden(reason: "Steam Client redistribution is never permitted")
        case .d3dmetal:
            return .forbidden(reason: "D3DMetal redistribution is forbidden until reviewed")
        }
    }

    // MARK: - Component-specific checks

    private static func evaluateWine(licenseSPDX: String, bundled: Bool) -> DistributionDecision {
        guard licenseSPDX == "LGPL-2.1-or-later" || licenseSPDX == "LGPL-2.1" else {
            return .reviewRequired(details: "Unexpected Wine license: \(licenseSPDX)")
        }
        if bundled {
            return .reviewRequired(details: "Wine bundled requires full license artifacts, patchset, and SBOM")
        }
        return .allowed
    }

    private static func evaluateDXVK(licenseSPDX: String, bundled: Bool) -> DistributionDecision {
        guard licenseSPDX == "Zlib" else {
            return .reviewRequired(details: "Unexpected DXVK license: \(licenseSPDX)")
        }
        if bundled {
            return .reviewRequired(details: "DXVK bundled requires upstream commit and binary SHA-256")
        }
        return .allowed
    }

    private static func evaluateMoltenVK(licenseSPDX: String, bundled: Bool) -> DistributionDecision {
        guard licenseSPDX == "Apache-2.0" else {
            return .reviewRequired(details: "Unexpected MoltenVK license: \(licenseSPDX)")
        }
        if bundled {
            return .reviewRequired(details: "MoltenVK bundled requires NOTICE, upstream commit, and SHA-256")
        }
        return .allowed
    }
}
