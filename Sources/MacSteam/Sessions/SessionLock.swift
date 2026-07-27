// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Error types for session lock operations.
enum SessionLockError: Error, Sendable, LocalizedError {
    case lockFailed(String)
    case lockHeldByAnotherSession(pid: Int32)
    case invalidPrefix
    case lockFileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .lockFailed(let msg): return "Failed to acquire session lock: \(msg)"
        case .lockHeldByAnotherSession(let pid): return "Session lock held by process \(pid)"
        case .invalidPrefix: return "Invalid prefix path"
        case .lockFileCreationFailed(let msg): return "Lock file creation failed: \(msg)"
        }
    }
}

/// An exclusive file lock for a single Wine prefix.
///
/// Uses Darwin `flock()` on a `.lock` file inside the MacsTeam Sessions
/// directory. Ensures that at most one active session exists per prefix.
///
/// The lock is released when this instance is deallocated, or explicitly
/// via `release()`.
final class SessionLock: @unchecked Sendable {
    private var fileDescriptor: Int32 = -1

    let prefixID: String
    let lockURL: URL

    /// Whether this instance currently holds the lock.
    private(set) var isHeld: Bool = false

    /// Create a session lock for the given prefix identifier.
    /// The lock file is stored at:
    /// `<Application Support>/MacSteam/Sessions/<prefixID>.lock`
    init(prefixID: String) throws {
        self.prefixID = prefixID
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
    /// Blocks until the lock is acquired or fails.
    ///
    /// - Returns: `true` if the lock was successfully acquired.
    /// - Throws: `SessionLockError` if the lock cannot be obtained.
    func acquire() throws -> Bool {
        let fd = try createOrOpenLockFile()
        fileDescriptor = fd

        // Try non-blocking first to report who holds it
        var ret = flock(fd, LOCK_EX | LOCK_NB)
        if ret != 0 {
            let err = errno
            if err == EWOULDBLOCK {
                // Someone else holds the lock
                let holder = try readHolderPID()
                throw SessionLockError.lockHeldByAnotherSession(pid: holder)
            }
            throw SessionLockError.lockFailed(String(cString: strerror(err)))
        }

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
    static func isLocked(prefixID: String) -> Bool {
        guard let lock = try? SessionLock(prefixID: prefixID) else { return false }
        return lock.testLockHeld()
    }

    /// Get the PID of the process currently holding the lock, if any.
    static func currentHolderPID(prefixID: String) -> Int32? {
        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Sessions")
        let lockURL = sessionsDir.appendingPathComponent("\(prefixID).lock")
        guard let data = try? Data(contentsOf: lockURL),
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
