// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

/// Error types for session lock operations.
enum SessionLockError: Error, Sendable, LocalizedError {
    case lockFailed(String)
    case lockHeldByAnotherSession(pid: Int32)
    case invalidPrefix
    case prefixOutsideAllowedRoot(URL)
    case lockFileCreationFailed(String)
    case fdLeakAfterFailure

    var errorDescription: String? {
        switch self {
        case .lockFailed(let msg): return "Failed to acquire session lock: \(msg)"
        case .lockHeldByAnotherSession(let pid): return "Session lock held by process \(pid)"
        case .invalidPrefix: return "Invalid prefix path"
        case .prefixOutsideAllowedRoot(let url): return "Prefix \(url.path) is outside allowed MacSteam prefix roots"
        case .lockFileCreationFailed(let msg): return "Lock file creation failed: \(msg)"
        case .fdLeakAfterFailure: return "Lock file descriptor was not cleaned up after failure"
        }
    }
}

/// Allowed prefix roots for MacSteam-managed sessions.
private let allowedPrefixRoots: [URL] = [
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/MacSteam/Prefixes"),
]

/// An exclusive file lock for a single Wine prefix.
///
/// Uses Darwin `flock()` on a `.lock` file inside the MacsTeam Sessions
/// directory. Ensures that at most one active session exists per prefix.
///
/// **U1R7:** Prefix identification uses a SHA-256 digest of the canonical
/// prefix path, not `lastPathComponent`.  Lock-failure paths always close
/// the file descriptor.  Prefixes are validated against allowed roots.
///
/// The lock is released when this instance is deallocated, or explicitly
/// via `release()`.
final class SessionLock: @unchecked Sendable {
    private var fileDescriptor: Int32 = -1

    let prefixID: String
    let lockURL: URL
    let canonicalPrefixURL: URL

    /// Whether this instance currently holds the lock.
    private(set) var isHeld: Bool = false

    /// Derive a stable prefix ID from the canonical prefix URL.
    /// Uses SHA-256 of the resolved, symlink-resolved path.
    static func derivePrefixID(_ prefix: URL) throws -> String {
        let resolved = try canonicalize(prefix)
        let digest = SHA256.hash(data: Data(resolved.path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonicalize a prefix URL: resolve symlinks and standardize.
    static func canonicalize(_ url: URL) throws -> URL {
        let standard = url.standardizedFileURL
        let resolved = standard.resolvingSymlinksInPath()
        return resolved
    }

    /// Validate that a prefix URL is within an allowed root.
    static func validatePrefixRoot(_ url: URL) throws {
        let canonical = try canonicalize(url)
        let allowed = try allowedPrefixRoots.map { try canonicalize($0) }

        guard allowed.contains(where: { canonical.path.hasPrefix($0.path + "/") || canonical.path == $0.path })
        else {
            throw SessionLockError.prefixOutsideAllowedRoot(canonical)
        }
    }

    /// Create a session lock for a prefix.
    /// The lock file is stored at:
    /// `<Application Support>/MacSteam/Sessions/<derivedPrefixID>.lock`
    init(prefix: URL) throws {
        let canonical = try Self.canonicalize(prefix)
        self.canonicalPrefixURL = canonical

        // Validate prefix is within allowed roots
        try Self.validatePrefixRoot(canonical)

        self.prefixID = try Self.derivePrefixID(canonical)

        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Sessions")

        try FileManager.default.createDirectory(at: sessionsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        self.lockURL = sessionsDir.appendingPathComponent("\(prefixID).lock")
    }

    deinit {
        if isHeld {
            release()
        }
    }

    /// Acquire an exclusive (write) lock on the prefix.
    ///
    /// - Returns: `true` if the lock was successfully acquired.
    /// - Throws: `SessionLockError` if the lock cannot be obtained.
    func acquire() throws -> Bool {
        let fd = try createOrOpenLockFile()

        // Try non-blocking first to report who holds it
        let ret = flock(fd, LOCK_EX | LOCK_NB)
        guard ret == 0 else {
            let savedErrno = errno
            close(fd) // MUST close before throwing
            fileDescriptor = -1
            if savedErrno == EWOULDBLOCK {
                let holder = try readHolderPID()
                throw SessionLockError.lockHeldByAnotherSession(pid: holder)
            }
            throw SessionLockError.lockFailed(String(cString: strerror(savedErrno)))
        }

        fileDescriptor = fd

        // Write our PID as holder
        let pidStr = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(fd, 0)
        write(fd, (pidStr as NSString).utf8String, pidStr.utf8.count)
        fsync(fd)

        isHeld = true
        return true
    }

    /// Release the lock.
    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
        isHeld = false
    }

    /// Check if the lock is currently held by any process.
    static func isLocked(prefix: URL) -> Bool {
        guard let lock = try? SessionLock(prefix: prefix) else { return false }
        return lock.testLockHeld()
    }

    /// Get the PID of the process currently holding the lock, if any.
    static func currentHolderPID(prefix: URL) -> Int32? {
        guard let lock = try? SessionLock(prefix: prefix) else { return nil }
        guard let data = try? Data(contentsOf: lock.lockURL),
              let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(str) else { return nil }
        return pid
    }

    // MARK: - Private

    private func createOrOpenLockFile() throws -> Int32 {
        let fm = FileManager.default

        // Create lock file if it doesn't exist
        if !fm.fileExists(atPath: lockURL.path) {
            let created = fm.createFile(atPath: lockURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
            guard created else {
                throw SessionLockError.lockFileCreationFailed(lockURL.path)
            }
        }

        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw SessionLockError.lockFailed(String(cString: strerror(errno)))
        }
        return fd
    }

    private func readHolderPID() throws -> Int32 {
        let data = try Data(contentsOf: lockURL)
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int32(str) ?? 0
    }

    private func testLockHeld() -> Bool {
        guard let fd = try? createOrOpenLockFile() else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }
}
