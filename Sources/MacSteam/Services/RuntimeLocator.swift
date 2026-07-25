// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Locates compatibility runtime bundles on the system.
///
/// Searches standard locations and validates bundles by identifier
/// and executable presence.
class RuntimeLocator: @unchecked Sendable {

    /// Standard search locations for CrossOver.
    private let crossoverSearchPaths: [String] = [
        "/Applications/CrossOver.app",
        NSHomeDirectory() + "/Applications/CrossOver.app"
    ]

    /// Locate the preferred runtime (currently CrossOver only).
    /// Returns `nil` if no valid runtime is found.
    func locatePreferredRuntime() -> (any CompatibilityRuntime)? {
        for path in crossoverSearchPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""

            // Quick pre‑check that this is actually CrossOver
            guard bundleID == "com.codeweavers.CrossOver" else { continue }

            let runtime = CrossOverRuntime(bundleURL: url)
            return runtime
        }

        return nil
    }

    /// Locate a runtime at an arbitrary user‑chosen URL.
    func locateRuntime(at url: URL) -> (any CompatibilityRuntime)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        switch bundleID {
        case "com.codeweavers.CrossOver":
            return CrossOverRuntime(bundleURL: url)
        default:
            return nil
        }
    }

    /// Check whether a previously stored runtime URL is still valid.
    func validateStoredRuntime(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        return bundleID == "com.codeweavers.CrossOver"
    }
}
