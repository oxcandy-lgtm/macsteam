// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Lock file metadata

struct AppInstanceInfo: Codable, Sendable {
    let pid: Int32
    let processStartTime: Date
    let buildID: String
    let executableFingerprint: String
}

/// Outcome of attempting to acquire the single-instance lock.
enum AcquisitionResult: Sendable, Equatable {
    /// This process now holds the lock — proceed with UI.
    case primary
    /// Another live instance holds the lock — caller should activate it and exit.
    case secondary(holderPID: Int32)
}

// MARK: - Flock-based single-instance guard (synchronous, fail-closed)

final class AppInstanceGuard {
    static let lockPath = "~/Library/Application Support/MacSteam/Locks/ui-instance.lock"

    private var lockFD: Int32 = -1
    private var lockHandle: FileHandle?

    /// Acquire the lock or activate the existing instance.
    ///
    /// Must be called before any UI is created. If the lock can't be acquired
    /// (I/O error, permissions), throws — caller must not proceed.
    func acquireOrActivateExisting(buildID: String) throws -> AcquisitionResult {
        let expandedPath = resolvePath()
        try ensureDirectoryExists(for: expandedPath)

        let fd = open(expandedPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        // Attempt non-blocking exclusive lock
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // Fast path: we own the lock
            lockFD = fd
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            lockHandle = handle
            try writeLockMetadata(buildID: buildID, fd: fd, handle: handle)
            return .primary
        }

        // Real error (not EWOULDBLOCK)
        if errno != EWOULDBLOCK {
            let saved = errno
            close(fd)
            throw POSIXError(.init(rawValue: saved) ?? .EIO)
        }

        // Lock held by another process — check staleness
        if evaluateStaleness(at: expandedPath) {
            // Stale lock: block until kernel releases it, then claim
            guard flock(fd, LOCK_EX) == 0 else {
                let saved = errno
                close(fd)
                throw POSIXError(.init(rawValue: saved) ?? .EIO)
            }
            lockFD = fd
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            lockHandle = handle
            try writeLockMetadata(buildID: buildID, fd: fd, handle: handle)
            return .primary
        }

        // Live lock holder — read its PID for activation
        close(fd)
        let holderPID = readHolderPIDFromLock(at: expandedPath)
        return .secondary(holderPID: holderPID ?? 0)
    }

    /// Release the lock. Must be called after cleanup completes.
    func release() {
        guard let handle = lockHandle else { return }
        flock(handle.fileDescriptor, LOCK_UN)
        lockHandle = nil
        lockFD = -1
    }

    deinit {
        if let handle = lockHandle {
            flock(handle.fileDescriptor, LOCK_UN)
        }
    }

    // MARK: - Private

    private func resolvePath() -> String {
        (Self.lockPath as NSString).expandingTildeInPath
    }

    private func ensureDirectoryExists(for path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

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
        try handle.synchronize()
    }

    private func evaluateStaleness(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let info = try? JSONDecoder().decode(AppInstanceInfo.self, from: data) else {
            return true // can't read — assume stale
        }
        return kill(info.pid, 0) != 0 // process not alive
    }

    private func readHolderPIDFromLock(at path: String) -> Int32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let info = try? JSONDecoder().decode(AppInstanceInfo.self, from: data) else {
            return nil
        }
        return info.pid
    }

    private func computeExecutableFingerprint() -> String {
        guard let execURL = Bundle.main.executableURL,
              let data = try? Data(contentsOf: execURL) else { return "unknown" }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            // Simple FNV-1a hash for the fingerprint (not crypto-grade)
            var h: UInt64 = 14695981039346656037
            for byte in buf.bindMemory(to: UInt8.self) {
                h ^= UInt64(byte)
                h &*= 1099511628211
            }
            withUnsafeMutableBytes(of: &hash) { hb in
                let ptr = hb.bindMemory(to: UInt64.self)
                ptr[0] = h
                ptr[1] = h ^ 0x9E3779B97F4A7C15
            }
        }
        return Data(hash).base64EncodedString().prefix(16).description
    }
}
