// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Zero-knowledge classification for Steam authentication artifacts.
///
/// MacSteam never reads or stores Steam credentials, sessions, cookies,
/// or authentication files. This enum provides a fail-closed policy:
/// unknown patterns are rejected.
enum SteamSensitiveCategory: String, Sendable, CaseIterable {
    case password
    case steamGuard
    case sessionToken
    case cookie
    case machineAuthorization
    case authenticationFile
    case browserProfile
    case crashMemoryDump
    case accountIdentifier

    var description: String { rawValue }
}

/// Policy engine that decides which URLs and arguments are allowed
/// through the zero-knowledge boundary.
struct SteamSensitiveDataPolicy: Sendable {

    /// Returns `true` if the URL refers to known-sensitive Steam data.
    static func isSensitive(_ url: URL) -> Bool {
        let path = url.standardized.path
        // Check directory prefixes (may or may not have trailing slash)
        if deniedPathPrefixes.contains(where: { prefix in
            path.contains(prefix) || path.contains(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }) {
            return true
        }
        // Check exact filenames
        if deniedFilenames.contains(where: { name in
            path.hasSuffix("/\(name)") || path.contains("/\(name)/")
        }) {
            return true
        }
        // Check filename prefixes (e.g. ssfn*)
        if deniedFilenamePrefixes.contains(where: { prefix in
            path.components(separatedBy: "/").last?.hasPrefix(prefix) ?? false
        }) {
            return true
        }
        // Check extensions
        if deniedExtensions.contains(where: { ext in
            path.hasSuffix(ext)
        }) {
            return true
        }
        return false
    }

    /// Returns `true` if a process argument contains known-sensitive patterns.
    static func isSensitiveArgument(_ arg: String) -> Bool {
        let lower = arg.lowercased()
        return sensitiveArgumentPatterns.contains { pattern in
            lower.contains(pattern)
        }
    }

    /// Returns `true` if an environment variable key is on the sensitive list.
    static func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        sensitiveEnvironmentKeys.contains(key.uppercased())
    }

    // MARK: - Deny lists

    private static let deniedPathPrefixes: Set<String> = [
        "/htmlcache/",
        "/webcache/",
        "/appcache/httpcache/",
        "/userdata/",
        "/Local Storage/",
        "/Session Storage/",
        "/IndexedDB/",
    ]

    private static let deniedFilenames: Set<String> = [
        "loginusers.vdf",
        "config.vdf",
        "ssfn",
        "Cookies",
        "Network Persistent State",
    ]

    private static let deniedExtensions: Set<String> = [
        ".dmp",
        ".mdmp",
        ".core",
    ]

    /// Prefix-based filename deny list (e.g. ssfn* matches ssfn123456789).
    private static let deniedFilenamePrefixes: Set<String> = [
        "ssfn",
    ]

    private static let sensitiveArgumentPatterns: Set<String> = [
        // SteamCMD login credentials
        "+login",
        "+set_steam_guard_code",
        // Common token patterns
        "access_token=",
        "refresh_token=",
        "steamLoginSecure=",
        "sessionid=",
        // Steam Guard / authenticator
        "steamguard",
        "machineauth",
        "oauth",
    ]

    private static let sensitiveEnvironmentKeys: Set<String> = [
        "STEAM_PASSWORD",
        "STEAM_GUARD",
        "STEAM_TOKEN",
        "STEAM_LOGIN",
        "ACCESS_TOKEN",
        "REFRESH_TOKEN",
        "SESSIONID",
        "COOKIE",
        "STEAM_USER",
        "STEAM_LOGINKEY",
    ]
}
