// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Path deny list that prevents MacSteam from reading Steam authentication
/// files, crash dumps, and browser profiles.
///
/// All methods are fail-closed: unknown paths are denied rather than
/// allowed by default.
struct SteamPathDenylist: Sendable {

    /// Returns `true` if the URL should be blocked.
    static func isDenied(_ url: URL) -> Bool {
        deniedGlobs.contains { glob in
            matches(glob: glob, url: url)
        }
    }

    /// Returns `true` if the URL matches an allowlisted pattern.
    static func isAllowed(_ url: URL) -> Bool {
        allowedGlobs.contains { glob in
            matches(glob: glob, url: url)
        } && !isDenied(url)
    }

    // MARK: - Steam app manifest access (allowlisted)

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

    // MARK: - Denied path globs

    private static let deniedGlobs: Set<String> = [
        "**/loginusers.vdf",
        "**/ssfn*",
        "**/config/config.vdf",
        "**/htmlcache/**",
        "**/webcache/**",
        "**/appcache/httpcache/**",
        "**/userdata/**",
        "**/Cookies",
        "**/Local Storage/**",
        "**/Session Storage/**",
        "**/IndexedDB/**",
        "**/*.dmp",
        "**/*.mdmp",
        "**/*.core",
    ]

    /// Allowlisted paths that bypass the deny list.
    private static let allowedGlobs: Set<String> = [
        "**/steamapps/appmanifest_*.acf",
        "**/steamapps/common/**",
    ]

    /// Simple glob matching using `fnmatch`-style patterns.
    /// Supports `**` for recursive directories and `*` for single-segment.
    private static func matches(glob: String, url: URL) -> Bool {
        let path = url.standardized.path
        // Convert glob to regex
        var pattern = NSRegularExpression.escapedPattern(for: glob)
        // Replace **/ with (.*/)?
        pattern = pattern
            .replacingOccurrences(of: "\\*\\*/", with: "([^:]*/)?")
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
        pattern = "^" + pattern + "$"
        return range(of: pattern, in: path) != nil
    }

    private static func range(of pattern: String, in string: String) -> Range<String.Index>? {
        try? NSRegularExpression(pattern: pattern).firstMatch(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.utf16.count)
        ).map { Range($0.range, in: string)! }
    }
}
