// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Bounded persistence outcome for a local acceptance receipt save/load.
///
/// Raw `Error.localizedDescription`, filesystem paths, and internal errors are
/// never surfaced; every outcome is a bounded symbol a consumer can map to
/// deterministic UI and a bounded blocker.
enum LocalAcceptanceReceiptStoreResult: Sendable, Equatable {
    case saved
    case notFound
    case loaded(LocalAcceptanceReceipt)
    case failed(LocalAcceptanceReceiptStoreError)
}

/// Bounded, deterministic storage errors. A consumer maps these symbols to
/// bounded UI; raw paths or error text are never surfaced.
enum LocalAcceptanceReceiptStoreError: String, Sendable, Equatable {
    case notAccepted = "receipt_not_accepted"
    case blockerNotNone = "receipt_blocker_not_none"
    case evidenceIncomplete = "receipt_evidence_incomplete"
    case targetMismatch = "receipt_target_mismatch"
    case visibilityBelowMinimum = "receipt_visibility_below_minimum"
    case securityFlagSet = "receipt_security_flag_set"
    case oversized = "receipt_oversized"
    case malformedJSON = "receipt_malformed_json"
    case nonCanonicalBytes = "receipt_non_canonical_bytes"
    case symlinkDestinationRejected = "receipt_symlink_destination"
    case symlinkParentEscapeRejected = "receipt_symlink_parent_escape"
    case nonRegularFile = "receipt_not_regular_file"
    case ioFailure = "receipt_io_failure"
}

/// Persists only __accepted__ local acceptance receipts as the exact
/// ``LocalAcceptanceReceipt.deterministicJSON`` bytes, and loads them back only
/// through a strict canonical-byte + semantic gate.
///
/// Contract:
///   * Only `accepted` receipts can be saved. `.blocked`, `.inProgress` and
///     `.invalidated` receipts are rejected. Save validity is judged by the full
///     semantic gate (status, blocker, target, every evidence flag, stability
///     threshold, and every security flag) — never by `status.state` alone.
///   * The bytes written are exactly `receipt.deterministicJSON`. No pretty
///     printing, timestamps, PIDs, UUIDs, usernames, absolute paths, raw error
///     text, or runtime executable paths are appended.
///   * The write is a same-directory POSIX transaction: a unique `O_EXCL` temp
///     is created in the parent directory, written with the exact canonical
///     bytes, `fchmod`ed to `0600`, `fsync`ed, then atomically `rename`d over
///     the destination and the directory is `fsync`ed. A failure removes only
///     the temp — the last-known-good receipt is never deleted.
///   * Load is fail-closed and bounded through a single non-following file
///     descriptor: the parent directory is opened `O_DIRECTORY|O_NOFOLLOW`, the
///     receipt is opened relative to it with
///     `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`, the exact opened FD is
///     `fstat`ed (regular-file proof + size bound) and bounded-read via the same
///     FD, then decode → accepted semantic validation → deterministic
///     re-encode → disk bytes == canonical bytes. Unknown fields, extra payload
///     and non-canonical serialization all fail closed.
///   * `.notFound` is returned only for an absent receipt (ENOENT). Permission
///     denial, open/read/stat failure, filesystem races and non-missing I/O
///     errors surface as `.ioFailure`; a symlink is rejected exactly.
///   * Filesystem safety: private (0700) parent dir, `0600` receipt, symlink
///     destination / symlink parent-escape rejection, and non-regular nodes
///     (directory, symlink, FIFO, socket, device) rejected as `nonRegularFile`
///     before any read.
struct LocalAcceptanceReceiptStore {
    nonisolated static let relativeReceiptPath = "Acceptance/cloverpit.json"
    nonisolated static let maxReceiptBytes: Int = 1 << 12
    nonisolated static let parentDirectoryPermissions = 0o700
    nonisolated static let receiptFilePermissions = 0o600
    nonisolated static let requiredStabilitySeconds: Int = 30

    private let applicationSupportRoot: URL
    private let fileManager: FileManager

    private var acceptanceRoot: URL {
        applicationSupportRoot.appendingPathComponent("Acceptance")
    }

    private var receiptPath: String { receiptURL.path }
    private var parentPath: String { acceptanceRoot.path }
    private var receiptURL: URL { acceptanceRoot.appendingPathComponent("cloverpit.json") }

    /// Standard store rooted at the MacSteam Application Support namespace.
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.init(applicationSupportRoot: base.appendingPathComponent("MacSteam"),
                  fileManager: .default)
    }

    /// Injectable temporary-root store for tests. Never touches the real user
    /// Application Support.
    init(applicationSupportRoot: URL, fileManager: FileManager = .default) {
        self.applicationSupportRoot = applicationSupportRoot
        self.fileManager = fileManager
    }

    // MARK: - Save

    /// Persists an accepted receipt exactly once. Returns `.saved` only when the
    /// independent semantic gate passes and the canonical bytes were written
    /// atomically into a bounded private namespace.
    @discardableResult
    func saveAccepted(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        if let failure = acceptedSemanticGate(receipt) {
            return .failed(failure)
        }
        if isSymlink(at: parentPath) { return .failed(.symlinkParentEscapeRejected) }
        if isSymlink(at: receiptPath) { return .failed(.symlinkDestinationRejected) }
        guard normalizePrivateParent() else { return .failed(.ioFailure) }
        return writeCanonical(receipt)
    }

    /// Independent semantic gate for accepted persistence. Returns nil only when
    /// every accepted contract holds: accepted status, blocker none, canonical
    /// target, every required evidence true, stability >= 30, all security false.
    func acceptedSemanticGate(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreError? {
        guard receipt.schemaVersion == 1,
              receipt.kind == "macsteam_local_runtime_acceptance" else {
            return .malformedJSON
        }
        if receipt.target != LocalAcceptanceReceipt.Target.canonical { return .targetMismatch }
        if receipt.status.state != .accepted { return .notAccepted }
        if receipt.status.blocker.lowercased() != "none" { return .blockerNotNone }

        let e = receipt.evidence
        if !e.importedWineSelected
            || !e.runtimeRealLoadHealthy
            || !e.canonicalPrefixBound
            || !e.steamInstallVerified
            || !e.cloverpitInstallReady
            || !e.supervisedGameSessionStarted
            || !e.ownershipCensusProven
            || !e.targetWindowVisible
            || !e.mainMenuConfirmedByOperator
            || !e.inputResponseConfirmedByOperator
            || !e.cleanupComplete {
            return .evidenceIncomplete
        }
        if e.visibilityStableSeconds < Self.requiredStabilitySeconds {
            return .visibilityBelowMinimum
        }
        let s = receipt.security
        if s.credentialsAccessed || s.rawPIDEmitted || s.rawPathEmitted
            || s.rawSessionIDEmitted || s.rawWindowIdentityEmitted {
            return .securityFlagSet
        }
        return nil
    }

    // MARK: - Load

    /// Loads and re-verifies the persisted accepted receipt. Returns `.notFound`
    /// when no receipt exists and `.failed` for any size / symlink / regular-file
    /// / canonical-byte / semantics violation. This is a historical-evidence
    /// load only, performed through a single non-following file descriptor; it
    /// never promotes the caller's current acceptance state.
    func loadAccepted() -> LocalAcceptanceReceiptStoreResult {
        // Open the parent directory without following a final symlink. A missing
        // parent is simply "no receipt"; a symlink parent or any other I/O error
        // is a bounded failure.
        let dirFD = parentPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if dirFD < 0 {
            if errno == ENOENT { return .notFound }
            if errno == ELOOP { return .failed(.symlinkParentEscapeRejected) }
            return .failed(.ioFailure)
        }
        defer { close(dirFD) }

        // Open the receipt relative to the parent directory FD, refusing to
        // follow a symlink and opening non-blocking so a FIFO cannot block.
        let relName = "cloverpit.json"
        let fileFD = relName.withCString {
            openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if fileFD < 0 {
            if errno == ENOENT { return .notFound }
            if errno == ELOOP { return .failed(.symlinkDestinationRejected) }
            return .failed(.ioFailure)
        }
        defer { close(fileFD) }

        // The single opened FD is the authority: fstat and read use the same FD.
        var st = stat()
        if fstat(fileFD, &st) != 0 { return .failed(.ioFailure) }
        // Require an actual regular file before touching the data road. Any
        // non-regular node (symlink, directory, FIFO, socket, device) is rejected.
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failed(.nonRegularFile) }
        if Int(st.st_size) > Self.maxReceiptBytes { return .failed(.oversized) }

        // Bounded read from the same FD: never read past maxReceiptBytes + 1.
        var buffer = [UInt8](repeating: 0, count: Self.maxReceiptBytes + 1)
        var total = 0
        while total < buffer.count {
            let n = read(fileFD, &buffer[total], buffer.count - total)
            if n < 0 {
                if errno == EINTR { continue }
                return .failed(.ioFailure)
            }
            if n == 0 { break }
            total += Int(n)
        }
        if total > Self.maxReceiptBytes { return .failed(.oversized) }
        let diskBytes = Data(buffer.prefix(total))

        guard let decoded = decodeCanonical(diskBytes) else { return .failed(.malformedJSON) }
        if let failure = acceptedSemanticGate(decoded) { return .failed(failure) }
        if decoded.deterministicJSON != diskBytes { return .failed(.nonCanonicalBytes) }
        return .loaded(decoded)
    }

    /// Strict decode against the schema's fixed CodingKeys. Carries no
    /// timestamps/PIDs/UUIDs/paths; only bounded booleans/ints/enums.
    private func decodeCanonical(_ bytes: Data) -> LocalAcceptanceReceipt? {
        try? JSONDecoder().decode(LocalAcceptanceReceipt.self, from: bytes)
    }

    // MARK: - Filesystem safety

    private func isSymlink(at path: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func normalizePrivateParent() -> Bool {
        do {
            try fileManager.createDirectory(at: acceptanceRoot, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: Self.parentDirectoryPermissions])
            // Ensure the leaf is not a symlink and is private.
            if isSymlink(at: parentPath) { return false }
            try fileManager.setAttributes([.posixPermissions: Self.parentDirectoryPermissions],
                                          ofItemAtPath: parentPath)
            return true
        } catch {
            return false
        }
    }

    private func removeTemp(at dirFD: Int32, name: String) {
        _ = name.withCString { unlinkat(dirFD, $0, 0) }
    }

    // MARK: - Canonical atomic write (same-directory POSIX transaction)

    /// Writes the exact canonical bytes through an atomic same-directory POSIX
    /// transaction. On any failure ONLY the temp is removed; a pre-existing
    /// last-known-good receipt is never deleted.
    private func writeCanonical(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        let data = receipt.deterministicJSON
        let dirFD = parentPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if dirFD < 0 { return .failed(.ioFailure) }
        defer { close(dirFD) }

        // Unique temp created exclusively in the same directory.
        let tempName = ".cloverpit-\(UUID().uuidString).tmp"
        let tempFD = tempName.withCString {
            openat(dirFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                   mode_t(S_IRUSR | S_IWUSR))
        }
        if tempFD < 0 { return .failed(.ioFailure) }

        var writeFailed = false
        var wrote = 0
        while wrote < data.count {
            var count = 0
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                let r = write(tempFD, base.advanced(by: wrote), data.count - wrote)
                count = r == -1 ? -1 : Int(r)
            }
            if count < 0 {
                if errno == EINTR { continue }
                writeFailed = true
                break
            }
            wrote += count
        }
        if !writeFailed, fchmod(tempFD, mode_t(S_IRUSR | S_IWUSR)) != 0 {
            writeFailed = true
        }
        if !writeFailed, fsync(tempFD) != 0 {
            writeFailed = true
        }
        if close(tempFD) != 0 { writeFailed = true }
        if writeFailed {
            // Only the temp is removed — never a pre-existing receipt.
            removeTemp(at: dirFD, name: tempName)
            return .failed(.ioFailure)
        }

        // Atomic replace: rename never follows a destination symlink; it
        // replaces the directory entry itself.
        let tempPath = parentPath + "/" + tempName
        let renamed = tempPath.withCString { t in
            receiptPath.withCString { r in rename(t, r) }
        }
        if renamed != 0 {
            removeTemp(at: dirFD, name: tempName)
            return .failed(.ioFailure)
        }
        // Best-effort directory flush. The rename already succeeded.
        fsync(dirFD)
        return .saved
    }
}