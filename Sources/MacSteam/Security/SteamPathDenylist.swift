// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of a path authorisation check.
///
/// Unknown or unrecognised paths are denied by default (fail-closed).
enum SteamReadAuthorization: Sendable, Equatable {
    /// The path is an allowed app manifest; only the listed keys may be read.
    case allowManifest(keys: Set<String>)
    /// Executable metadata (existence, size, regular-file check) is permitted.
    case allowExecutableMetadata
    /// The path is denied.
    case deny
}

/// Path deny list that prevents MacSteam from reading Steam authentication
/// files, crash dumps, and browser profiles.
///
/// All methods are fail-closed: unknown paths are denied rather than
/// allowed by default.
struct SteamPathDenylist: Sendable {

    /// Authorise reading the given URL.
    ///
    /// - Parameter url: The URL to check.
    /// - Returns: An authorisation decision.  Default is `.deny`.
    static func authorizeRead(_ url: URL) -> SteamReadAuthorization {
        let std = url.standardized
        let path = std.path

        // App manifests are partially readable
        if matches(glob: "**/steamapps/appmanifest_*.acf", path: path) {
            return .allowManifest(keys: allowedManifestKeys)
        }

        // CloverPit executable metadata
        if path.hasSuffix("/CloverPit.exe")
            || path.hasSuffix("/UnityPlayer.dll")
            || path.hasSuffix("/UnityCrashHandler64.exe") {
            return .allowExecutableMetadata
        }

        // Game install directories
        if matches(glob: "**/steamapps/common/**", path: path) {
            // Common game files — allowed for detection purposes
            return .allowExecutableMetadata
        }

        // Everything else is denied
        return .deny
    }

    // MARK: - Manifest key allowlist

    /// Keys that may be read from an app manifest `.acf` file.
    static let allowedManifestKeys: Set<String> = [
        "appid",
        "installdir",
        "StateFlags",
        "BytesToDownload",
        "BytesDownloaded",
        "BytesToStage",
        "BytesStaged",
    ]

    /// Returns `true` if the manifest key is allowlisted.
    static func isAllowedManifestKey(_ key: String) -> Bool {
        allowedManifestKeys.contains(key)
    }

    // MARK: - Legacy compatibility (deprecated)

    @available(*, deprecated, message: "Use authorizeRead() instead")
    static func isDenied(_ url: URL) -> Bool {
        if case .deny = authorizeRead(url) { return true }
        return false
    }

    @available(*, deprecated, message: "Use authorizeRead() instead")
    static func isAllowed(_ url: URL) -> Bool {
        if case .deny = authorizeRead(url) { return false }
        return true
    }

    // MARK: - Private

    /// Simple glob matching.
    private static func matches(glob: String, path: String) -> Bool {
        var pattern = NSRegularExpression.escapedPattern(for: glob)
        // Unescape forward slashes (escapedPattern escapes / to \\/)
        pattern = pattern.replacingOccurrences(of: "\\/", with: "/")
        // Convert escaped glob tokens to regex
        pattern = pattern
            .replacingOccurrences(of: "\\*\\*/", with: "([^:]*/)?")
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
        pattern = "^" + pattern + "$"
        return (try? NSRegularExpression(pattern: pattern).firstMatch(
            in: path, options: [],
            range: NSRange(location: 0, length: path.utf16.count)
        )) != nil
    }
}
