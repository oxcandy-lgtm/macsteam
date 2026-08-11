// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bounded material file identity (U1R18-R13-FIX1-FIX2 §8).
///
/// A path is NOT material identity: replacing or modifying the bytes at the
/// same path must change this identity. It is derived from bounded stat-like
/// values (regular-file requirement, size, modification time, inode/device
/// where available) — never a raw path, inode, device, or an unbounded binary
/// load. The values are bounded safe derived identities only.
struct LaunchFileIdentity: Equatable, Sendable {
    let isRegularFile: Bool
    let size: UInt64
    let mtimeNanos: Int64
    let inode: UInt64?
    let device: UInt64?

    /// Bounded safe derived discriminator (not a path).
    var safeID: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(isRegularFile)|\(size)|\(mtimeNanos)|\(inode ?? 0)|\(device ?? 0)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Provider of bounded material file identity (injectable for tests).
protocol LaunchFileIdentityProviding: Sendable {
    func identity(for url: URL) -> LaunchFileIdentity?
}

/// Production file-identity provider backed by FileManager + stat.
struct SystemLaunchFileIdentityProvider: LaunchFileIdentityProviding {
    func identity(for url: URL) -> LaunchFileIdentity? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        let isRegular = type == .typeRegular
        let size = (attrs[.size] as? UInt64) ?? (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime: Int64
        if let date = attrs[.modificationDate] as? Date {
            mtime = Int64(date.timeIntervalSince1970 * 1_000_000_000)
        } else {
            mtime = 0
        }
        // inode/device via stat when available.
        var statBuf = stat()
        let rc = url.path.withCString { cstr in stat(cstr, &statBuf) }
        let inode = rc == 0 ? UInt64(statBuf.st_ino) : nil
        let device = rc == 0 ? UInt64(statBuf.st_dev) : nil
        return LaunchFileIdentity(
            isRegularFile: isRegular,
            size: size,
            mtimeNanos: mtime,
            inode: inode,
            device: device
        )
    }
}

/// Fingerprint of the validated launch prerequisites (U1R18-R13-FIX1 §9).
///
/// A fast path is admissible only when the material identity of the Imported
/// Wine runtime, the canonical prefix, and the Steam installation is unchanged
/// since a successful production validation. Fingerprints contain bounded safe
/// derived identities only — never raw paths.
struct LaunchValidationFingerprint: Equatable, Sendable {
    /// Material identity of the candidate Wine runtime executable.
    let runtimeIdentity: LaunchFileIdentity?
    /// Bounded safe hash of the canonical prefix (never a path).
    let prefixSafeID: String?
    /// Whether canonical prefix evidence is currently valid.
    let prefixEvidenceValid: Bool
    /// Material identity of the Steam executable.
    let steamIdentity: LaunchFileIdentity?
    /// Whether the runtime is Imported Wine (canonical U1 path).
    let importedWine: Bool
}

/// The validation path actually taken for an attempt (U1R18-R13-FIX1-FIX2 §12).
///
/// Frozen at the validation decision BEFORE cache publication. Never relabels
/// a full validation as "fast" merely because the cache became admissible.
enum LaunchValidationPath: Equatable, Sendable {
    case fullValidation
    case fastValidation
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