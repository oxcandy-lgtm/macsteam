// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds a safe, validated environment dictionary for Wine processes.
///
/// Managed keys that are always set by the builder:
///   - `WINEPREFIX` — from the validated prefix parameter
///   - `WINEARCH` — always `win64`
///   - `WINEDEBUG` — always `-all` (production mode)
///   - `DYLD_LIBRARY_PATH` — from `RuntimeDependencyLayout.libDirectory()` (if it exists)
///   - `FONTCONFIG_PATH` — from `RuntimeDependencyLayout.fontconfigDirectory()` (if it exists)
///   - `LANG` — always `ja_JP.UTF-8`
///   - `LC_CTYPE` — always `ja_JP.UTF-8`
///
/// User-supplied values for managed keys (`DYLD_LIBRARY_PATH`, `FONTCONFIG_PATH`,
/// `WINEPREFIX`) are **silently rejected** to prevent environment injection attacks.
///
/// Additional user-supplied keys are filtered through an allowlist, mirroring
/// `SafeProcessEnvironment` behaviour.
struct WineLaunchEnvironmentBuilder: Sendable {
    /// Keys that are completely managed by this builder. Any user-supplied
    /// value for these keys is silently dropped.
    private static let managedKeys: Set<String> = [
        "DYLD_LIBRARY_PATH",
        "FONTCONFIG_PATH",
        "WINEPREFIX",
    ]

    /// The validated prefix root URL.
    let winePrefix: URL

    /// The dependency layout for the runtime.
    let dependencyLayout: RuntimeDependencyLayout

    /// Creates a builder with a validated WINEPREFIX.
    ///
    /// - Parameters:
    ///   - winePrefix: The prefix directory URL. Must be inside the canonical
    ///     `~/Library/Application Support/MacSteam/Prefixes/` directory.
    ///   - dependencyLayout: The runtime dependency layout.
    /// - Throws: `WineEnvironmentError.invalidPrefix` if `winePrefix` is outside
    ///   the canonical prefixes directory.
    init(winePrefix: URL, dependencyLayout: RuntimeDependencyLayout) throws {
        let canonicalPrefixesDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
        guard PathBoundary.isInside(winePrefix, root: canonicalPrefixesDir) else {
            throw WineEnvironmentError.invalidPrefix(winePrefix)
        }
        self.winePrefix = winePrefix
        self.dependencyLayout = dependencyLayout
    }

    /// Build the environment dictionary.
    ///
    /// - Parameter additionalEnvironment: Optional user-supplied extra environment.
    ///   Values for `managedKeys` are silently dropped. All other keys are filtered
    ///   through an allowlist.
    /// - Returns: A fully-populated environment dictionary suitable for
    ///   `Process.environment`.
    func build(additionalEnvironment: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [:]

        // Core Wine environment (always set, never overridden by user)
        env["WINEPREFIX"] = winePrefix.path
        env["WINEARCH"] = "win64"
        env["WINEDEBUG"] = "-all"

        // Managed dependency paths (set only when the directories exist)
        let fm = FileManager.default
        let libDir = dependencyLayout.libDirectory()
        if fm.fileExists(atPath: libDir.path) {
            env["DYLD_LIBRARY_PATH"] = libDir.path
        }
        let fcDir = dependencyLayout.fontconfigDirectory()
        if fm.fileExists(atPath: fcDir.path) {
            env["FONTCONFIG_PATH"] = fcDir.path
        }

        // Locale (always set for consistent Japanese locale)
        env["LANG"] = "ja_JP.UTF-8"
        env["LC_CTYPE"] = "ja_JP.UTF-8"

        // Merge additional environment through the allowlist.
        // Managed keys are unconditionally rejected.
        for (key, value) in additionalEnvironment {
            guard !Self.managedKeys.contains(key) else { continue }
            guard Self.allowlistedKeys.contains(key) else { continue }
            env[key] = value
        }

        return env
    }

    // MARK: - Allowlist

    /// Allowlisted environment keys for user-supplied values.
    /// This mirrors `SafeProcessEnvironment.allowlistedKeys` while excluding
    /// the keys that are managed by this builder.
    private static let allowlistedKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "PATH", "TMPDIR",
        "LANG", "LC_ALL", "LC_MESSAGES", "LC_CTYPE",
        "WINEARCH", "WINEDEBUG",
        "DISPLAY", "WAYLAND_DISPLAY",
        "DXVK_HUD", "DXVK_STATE_CACHE",
        "STAGING_SHARED_MEMORY",
        "MTL_HUD_ENABLED",
    ]
}

/// Errors from `WineLaunchEnvironmentBuilder`.
enum WineEnvironmentError: Error, Sendable, LocalizedError {
    case invalidPrefix(URL)

    var errorDescription: String? {
        switch self {
        case .invalidPrefix(let url):
            return "WINEPREFIX is outside the canonical Prefixes directory: \(url.path)"
        }
    }
}
