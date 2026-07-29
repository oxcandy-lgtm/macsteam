// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Lock file metadata

struct AppInstanceInfo: Codable, Sendable {
    let pid: Int32
    let processStartTime: Date
    let buildID: String
    let executableFingerprint: String
}

// MARK: - Flock-based single-instance guard

actor AppInstanceGuard {
    /// Path to the lock file used for single-instance enforcement.
    static let lockPath = "~/Library/Application Support/MacSteam/Locks/ui-instance.lock"

    private var lockHandle: FileHandle?

    // -------------------------------------------------------------------------
    // MARK: Public API
    // -------------------------------------------------------------------------

    /// Attempt to acquire the single-instance lock.
    ///
    /// - Returns: `true` when this process now owns the lock; `false` when
    ///   another live instance already holds it (caller should exit).
    /// - Throws: `POSIXError` if the underlying file/lock operations fail.
    func acquire(buildID: String) throws -> Bool {
        let expandedPath = resolvePath()
        try ensureDirectoryExists(for: expandedPath)

        let fd = open(expandedPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        // --- Attempt non-blocking exclusive lock ---
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // Fast path: lock acquired immediately.
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.lockHandle = handle
            try writeLockMetadata(buildID: buildID, fd: fd, handle: handle)
            return true
        }

        // Anything other than EWOULDBLOCK is a real error.
        if errno != EWOULDBLOCK {
            let savedErrno = errno
            close(fd)
            throw POSIXError(.init(rawValue: savedErrno) ?? .EIO)
        }

        // --- Lock is held by another process → check for stale lock ---
        let stale = evaluateStaleness(at: expandedPath)

        guard stale else {
            // Another live instance holds the lock — signal the caller to exit.
            close(fd)
            return false
        }

        // Stale lock: block until it is released by the kernel (dead process
        // whose fd was closed), then claim it.
        guard flock(fd, LOCK_EX) == 0 else {
            let savedErrno = errno
            close(fd)
            throw POSIXError(.init(rawValue: savedErrno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.lockHandle = handle
        try writeLockMetadata(buildID: buildID, fd: fd, handle: handle)
        return true
    }

    /// Release the lock and close the underlying file descriptor.
    func release() {
        guard let handle = lockHandle else { return }
        flock(handle.fileDescriptor, LOCK_UN)
        self.lockHandle = nil // closeOnDealloc closes the fd
    }

    /// Read the PID of the current lock holder from the lock file.
    /// Returns nil if the lock file doesn't exist or can't be parsed.
    func readHolderPID() -> Int32? {
        let path = resolvePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let info = try? JSONDecoder().decode(AppInstanceInfo.self, from: data) else {
            return nil
        }
        return info.pid
    }

    deinit {
        if let handle = lockHandle {
            flock(handle.fileDescriptor, LOCK_UN)
            // closeOnDealloc handles closing the fd
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Private helpers
    // -------------------------------------------------------------------------

    /// Expand tilde and return the absolute lock-file path.
    private func resolvePath() -> String {
        (Self.lockPath as NSString).expandingTildeInPath
    }

    /// Create the parent directory for the lock file if it does not exist.
    private func ensureDirectoryExists(for path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Write fresh `AppInstanceInfo` into the lock file and sync to disk.
    private func writeLockMetadata(buildID: String, fd: Int32, handle: FileHandle) throws {
        let info = AppInstanceInfo(
            pid: ProcessInfo.processInfo.processIdentifier,
            processStartTime: Date(),
            buildID: buildID,
            executableFingerprint: computeExecutableFingerprint()
        )
        let data = try JSONEncoder().encode(info)

        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        try handle.write(contentsOf: data)
        try handle.synchronize() // fsync — flush to backing store
    }

    /// Read the raw bytes of an open file descriptor.
    private func readAll(fd: Int32) throws -> Data {
        var data = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = read(fd, &buf, bufSize)
            if n < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            data.append(&buf, count: n)
        }
        return data
    }

    /// Determine whether the current lock-file content belongs to a dead
    /// process (stale) or a live one.
    ///
    /// - Returns: `true` if the lock is stale and should be reclaimed.
    private func evaluateStaleness(at path: String) -> Bool {
        let rfd = open(path, O_RDONLY)
        guard rfd >= 0 else { return true } // can't open → unstuck by reclaim
        defer { close(rfd) }

        guard let data = try? readAll(fd: rfd), !data.isEmpty,
              let info = try? JSONDecoder().decode(AppInstanceInfo.self, from: data)
        else {
            return true // empty or unparseable → stale
        }

        // kill(pid, 0) returns 0  if the process exists and we have permission.
        //                -1 with errno == EPERM  → exists but cannot signal.
        //                -1 with errno == ESRCH  → process does not exist.
        if kill(info.pid, 0) == 0 {
            return false // alive
        }
        if errno == EPERM {
            return false // alive (no signal permission, but the PID is valid)
        }
        return true // ESRCH or other → dead → stale
    }

    /// Compute a lightweight fingerprint of the running executable.
    ///
    /// Uses `(file size, modification timestamp)` of the main bundle
    /// executable. This is **not** a cryptographic hash; it is sufficient
    /// for detecting that a competing instance was built from a different
    /// binary at a glance during stale-lock inspection.
    private func computeExecutableFingerprint() -> String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path)
        else {
            return "unknown"
        }
        let size    = attrs[.size] as? UInt64 ?? 0
        let modDate = attrs[.modificationDate] as? Date ?? Date()
        return "\(size)-\(Int(modDate.timeIntervalSince1970))"
    }
}

// MARK: - Activate an existing instance (AppKit)

#if canImport(AppKit)
import AppKit

/// Utility to bring an already-running MacSteam instance to the foreground.
class AppInstanceActivation {
    /// Locate the first running MacSteam process by bundle identifier and ask
    /// it to activate (frontmost, own menu bar, own space).
    ///
    /// - Returns: `true` if an existing instance was found and activation was
    ///   attempted; `false` if no matching process was running.
    @discardableResult
    static func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first
        else {
            return false
        }
        return app.activate(options: .activateIgnoringOtherApps)
    }
}
#endif
