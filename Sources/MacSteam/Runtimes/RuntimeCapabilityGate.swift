// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Maps recipe `requiredCapabilities` strings to `RuntimeCapabilities` bits
/// and provides the deterministic gate used during runtime selection.
enum RuntimeCapabilityGate: Sendable {

    /// Map a single recipe capability string to its bit.
    ///
    /// Supported strings match the recipe schema's stable kebab-case names.
    static func capability(from string: String) -> RuntimeCapabilities? {
        switch string {
        case "windows-process": return .windowsProcess
        case "steam-client":    return .steamClient
        case "isolated-prefix": return .isolatedPrefix
        case "d3d":             return .d3d
        case "vulkan":          return .vulkan
        case "metal":           return .metal
        case "wined3d":         return .wined3d
        case "wow64":           return .wow64
        default:                return nil
        }
    }

    /// Build the required capability set from recipe strings.
    ///
    /// Unknown strings are skipped (they never become hard requirements),
    /// keeping the gate deterministic and schema-version tolerant.
    static func required(from strings: [String]) -> RuntimeCapabilities {
        strings.reduce(into: RuntimeCapabilities()) { result, s in
            if let cap = capability(from: s) { result.insert(cap) }
        }
    }

    /// Effective capabilities of a runtime: its static inspection
    /// capabilities, plus `steamClient` when the real-load preflight proves
    /// the runtime can actually execute a Windows command.
    static func effectiveCapabilities(
        staticCaps: RuntimeCapabilities,
        realLoadHealthy: Bool
    ) -> RuntimeCapabilities {
        var effective = staticCaps
        if realLoadHealthy {
            effective.insert(.steamClient)
        }
        return effective
    }

    /// The human-readable names of the capabilities missing from `effective`.
    static func missingCapabilityNames(
        required: RuntimeCapabilities,
        effective: RuntimeCapabilities
    ) -> [String] {
        let missing = required.subtracting(effective)
        var names: [String] = []
        if missing.contains(.windowsProcess) { names.append("windows-process") }
        if missing.contains(.steamClient)    { names.append("steam-client") }
        if missing.contains(.isolatedPrefix) { names.append("isolated-prefix") }
        if missing.contains(.d3d)            { names.append("d3d") }
        if missing.contains(.vulkan)         { names.append("vulkan") }
        if missing.contains(.metal)          { names.append("metal") }
        if missing.contains(.wined3d)        { names.append("wined3d") }
        if missing.contains(.wow64)          { names.append("wow64") }
        return names
    }

    /// Whether the effective capability set satisfies every required bit.
    static func isSatisfied(required: RuntimeCapabilities, effective: RuntimeCapabilities) -> Bool {
        required.isSubset(of: effective)
    }
}
