// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Codable state written to a session receipt.
enum ReceiptSessionState: String, Codable, Sendable {
    case runningUnknown
    case runningVisible
}

/// Persisted active-session receipt.
///
/// NO real paths, identifiers, credentials, or environment values.
/// Only sessionID, recipeID, runtimeID, prefixID (safe hash), PID, and timestamp.
struct ActiveSessionReceipt: Codable, Sendable {
    let sessionID: UUID
    let recipeID: String
    let runtimeID: String
    let prefixID: String
    let rootPID: Int32
    let startedAt: Date
    let state: ReceiptSessionState
}

/// Errors from receipt store operations.
enum ReceiptStoreError: Error, Sendable, LocalizedError {
    case writeFailed(String)
    case readFailed(String)
    case invalidReceipt(String)
    case symlinkRejected(URL)
    case permissionsIncorrect(URL)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let msg): return "Receipt write failed: \(msg)"
        case .readFailed(let msg): return "Receipt read failed: \(msg)"
        case .invalidReceipt(let msg): return "Invalid receipt: \(msg)"
        case .symlinkRejected(let url): return "Symlink rejected at \(url.path)"
        case .permissionsIncorrect(let url): return "Incorrect permissions at \(url.path)"
        }
    }
}

/// Stores and reads active-session receipts on disk.
///
/// Storage: `~/Library/Application Support/MacSteam/Sessions/<prefixID>.json`
///
/// **U1R7:**
/// - Directory: 0700
/// - File: 0600
/// - Atomic write via temporary file + rename
/// - Symlink check on read (reject if target is a symlink)
/// - No real paths, account identifiers, commands, or environment
struct SessionReceiptStore {
    private let sessionsDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Sessions")
    }()

    /// Write a receipt for an active session.
    func write(session: GameSession, state: ReceiptSessionState) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])

        let prefixID = try SessionLock.derivePrefixID(session.prefixRoot)
        let receipt = ActiveSessionReceipt(
            sessionID: session.sessionID,
            recipeID: session.recipeID,
            runtimeID: session.runtimeID,
            prefixID: prefixID,
            rootPID: session.rootPID,
            startedAt: session.startedAt,
            state: state
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)

        let targetURL = sessionsDir.appendingPathComponent("\(prefixID).json")
        let tempURL = sessionsDir.appendingPathComponent(".\(prefixID).tmp")

        // Atomic write
        try data.write(to: tempURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        try fm.replaceItemAt(targetURL, withItemAt: tempURL,
                            backupItemName: nil, options: .usingNewMetadataOnly)
    }

    /// Read a receipt for the given prefix, if it exists and is valid.
    func read(prefix: URL) -> ActiveSessionReceipt? {
        guard let prefixID = try? SessionLock.derivePrefixID(prefix) else { return nil }
        let url = sessionsDir.appendingPathComponent("\(prefixID).json")

        let fm = FileManager.default

        // Reject symlinks
        guard !isSymlink(url) else { return nil }

        // Check file exists
        guard fm.fileExists(atPath: url.path) else { return nil }

        // Check permissions (must be 0600)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? Int,
              perms & 0o177 == 0 else { return nil }

        // Read and decode
        guard let data = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(ActiveSessionReceipt.self, from: data)
        else { return nil }

        return receipt
    }

    /// Remove a receipt.
    func remove(prefix: URL) {
        guard let prefixID = try? SessionLock.derivePrefixID(prefix) else { return }
        let url = sessionsDir.appendingPathComponent("\(prefixID).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Check all active receipts (for startup scan).
    func allActiveReceipts() -> [ActiveSessionReceipt] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles) else { return [] }

        return contents.compactMap { url in
            guard url.pathExtension == "json",
                  !isSymlink(url),
                  let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(ActiveSessionReceipt.self, from: data),
                  let perms = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
                  perms & 0o177 == 0
            else { return nil }
            return receipt
        }
    }

    // MARK: - Private

    private func isSymlink(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}
