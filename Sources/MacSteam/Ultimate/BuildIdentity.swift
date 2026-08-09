// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Developer-local build identity (U1R18-R13-FIX1 §3.3).
///
/// The synced developer app embeds an exact commit SHA and channel via the
/// bundle Info.plist keys set by `scripts/dev-sync-local-app.sh`. This type
/// reads those keys and never falls back to a git repository lookup at
/// runtime. When the app is launched via `swift run` (no embedded bundle
/// keys), it falls back to a safe derived identity that is clearly labelled
/// as a non-synced run so the user can tell they are not looking at the
/// synced app.
struct BuildIdentity: Equatable, Sendable {
    /// Short commit SHA (e.g. first 12 hex chars), or a safe fallback label.
    let commitSHA: String
    /// Channel label, e.g. "Developer Local".
    let channel: String
    /// Whether the identity was embedded by the dev-sync installer.
    let synced: Bool

    static let defaultChannel = "Developer Local"

    /// Identity read from the running bundle with a safe `swift run` fallback.
    ///
    /// The fallback must never claim to be a synced build, must never require
    /// a git repository, and must never differ spuriously across identical
    /// binaries (it is derived from the executable bytes, not wall-clock).
    static func current(bundle: Bundle = .main) -> BuildIdentity {
        let info = bundle.infoDictionary ?? [:]
        if let sha = info["MacsTeamBuildSHA"] as? String, !sha.isEmpty {
            return BuildIdentity(
                commitSHA: shortSHA(sha),
                channel: (info["MacsTeamBuildChannel"] as? String ?? defaultChannel),
                synced: true
            )
        }
        // `swift run` fallback: derive a stable identity from the executable
        // bytes (no git, no path in the user-visible label).
        let derived = derivedFromExecutable(bundle: bundle)
        return BuildIdentity(commitSHA: derived, channel: "\(defaultChannel) (run)", synced: false)
    }

    /// Normalize an arbitrary-length SHA to a bounded first-12 hex label.
    static func shortSHA(_ sha: String) -> String {
        String(sha.filter(\.isHexDigit).prefix(12))
    }

    /// Stable short identity derived from the current executable bytes.
    /// Returns "unknown" when the executable cannot be read.
    static func derivedFromExecutable(bundle: Bundle = .main) -> String {
        guard let url = bundle.executableURL,
              let data = try? Data(contentsOf: url) else { return "unknown" }
        return shortSHA(sha256Hex(data))
    }

    /// SHA-256 hex digest (CryptoKit-free, bounded) used only for a stable
    /// short run identity. Never emitted as a user-visible full path.
    static func sha256Hex(_ data: Data) -> String {
        // FNV-1a 64-bit is not a cryptographic hash, but this is only a stable
        // short run-identity discriminator, not a security boundary. It must
        // be deterministic across identical executables and cheap to compute.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}