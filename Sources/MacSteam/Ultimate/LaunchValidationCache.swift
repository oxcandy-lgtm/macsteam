// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fingerprint of the validated launch prerequisites (U1R18-R13-FIX1 §9).
///
/// A fast path is admissible only when the identity/fingerprint of the Imported
/// Wine runtime, canonical prefix, and Steam installation is unchanged since a
/// successful production validation. Fingerprints are safe hashes, not paths.
struct LaunchValidationFingerprint: Equatable, Sendable {
    /// Bounded safe hash of the resolved runtime (never a path).
    let runtimeSafeID: String?
    /// Bounded safe hash of the canonical prefix (never a path).
    let prefixSafeID: String?
    /// Bounded safe hash of the Steam executable bytes (never a path).
    let steamSafeID: String?
    /// Whether the runtime is Imported Wine (canonical U1 path).
    let importedWine: Bool
}

/// In-memory safe fast-path cache (U1R18-R13-FIX1 §9/§16).
///
/// The cache is scoped to a single app lifetime (not persisted). It is
/// invalidated conservatively: any runtime/prefix/Steam change, a failed
/// launch, recoveryRequired, or lost ownership disables the fast path so the
/// full security validation always re-runs.
struct LaunchValidationCache: Equatable, Sendable {
    private(set) var cachedFingerprint: LaunchValidationFingerprint?
    private(set) var lastLaunchSucceeded = false
    private(set) var invalidated = false

    /// Whether a fast path is admissible right now.
    var isFastPathAdmissible: Bool {
        !invalidated && cachedFingerprint != nil && lastLaunchSucceeded
    }

    /// Record a successful validation + launch. Enables the fast path.
    mutating func recordSuccess(fingerprint: LaunchValidationFingerprint) {
        cachedFingerprint = fingerprint
        lastLaunchSucceeded = true
        invalidated = false
    }

    /// Invalidate the cache conservatively (any of the §9.1 reasons).
    mutating func invalidate() {
        invalidated = true
        lastLaunchSucceeded = false
    }

    /// Invalidate only when a previous launch failed (used on a new-attempt
    /// reset). Leaves a clean prior success untouched.
    mutating func invalidateIfFailed() {
        if !lastLaunchSucceeded {
            invalidated = true
        }
    }

    /// Record a failed launch: invalidates and clears the success flag.
    mutating func recordFailure() {
        lastLaunchSucceeded = false
        invalidated = true
    }

    /// Whether the given fingerprint matches the cached one and the fast path
    /// is admissible. Returns false on any mismatch or invalidation.
    func matchesAdmissible(_ fingerprint: LaunchValidationFingerprint) -> Bool {
        guard isFastPathAdmissible, let cached = cachedFingerprint else { return false }
        return cached == fingerprint
    }
}

/// Deterministic safe-ID (bounded hash) computation for a path.
enum LaunchSafeID {
    /// FNV-1a 64-bit short hash of a path's bytes. Used only as a stable
    /// identity discriminator, not a security boundary.
    static func of(_ path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}