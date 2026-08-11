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

/// Internal syscall seam so snapshot-consistency and interrupted-syscall
/// behavior can be driven deterministically in tests. The production store
/// always uses `.live`; the seam is never exposed through a public API.
struct ReceiptFileOperations {
    var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    var fstat: @Sendable (Int32, inout stat) -> Int32

    static let live = ReceiptFileOperations(
        read: { fd, ptr, count in Darwin.read(fd, ptr, count) },
        write: { fd, ptr, count in Darwin.write(fd, ptr, count) },
        fstat: { fd, st in Darwin.fstat(fd, &st) }
    )
}

/// Outcome of the single-byte growth probe after the exact body read. Internal
/// only — never exposed through the public store API. Clean EOF is a distinct
/// legal terminal state, not an ioFailure.
enum GrowthProbeResult {
    case cleanEOF
    case growthDetected
    case ioFailure
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
///   * The write is a single directory-FD-bound POSIX transaction: the parent
///     directory is opened once (`O_DIRECTORY|O_NOFOLLOW`), a unique `O_EXCL`
///     temp is created with `openat`, written with the exact canonical bytes,
///     `fchmod`ed to `0600`, `fsync`ed, and installed with `renameat` where the
///     source and destination live in the SAME opened directory FD. No path is
///     re-resolved after the temp is created. A failure removes only the temp
///     (`unlinkat` on the same FD) — the last-known-good receipt is never
///     deleted.
///   * Load is a snapshot-consistent fail-closed read through a single
///     non-following file descriptor: open the parent `O_DIRECTORY|O_NOFOLLOW`,
///     `openat` the receipt `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`, `fstat`
///     the exact FD (regular-file proof + size bound), read EXACTLY the
///     pre-stat size (short read / extra byte / any pre↔post metadata change is
///     an `ioFailure`), re-`fstat` the same FD, then decode → accepted semantic
///     validation → deterministic re-encode → disk bytes == canonical bytes.
///   * Every `read`/`write` EINTR is retried only up to a bounded
///     `maxInterruptedSyscallRetries`; a zero-progress write fails closed. No
///     syscall loop can run forever.
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
    /// Bound for EINTR retry on any single read/write syscall. 4…16 is the
    /// allowed range; an exhausted bound is a bounded `ioFailure`.
    nonisolated static let maxInterruptedSyscallRetries = 8

    private let applicationSupportRoot: URL
    private let fileManager: FileManager
    private let ops: ReceiptFileOperations

    private var acceptanceRoot: URL {
        applicationSupportRoot.appendingPathComponent("Acceptance")
    }

    private var receiptPath: String { receiptURL.path }
    private var parentPath: String { acceptanceRoot.path }
    private var receiptURL: URL { acceptanceRoot.appendingPathComponent("cloverpit.json") }
    private static let receiptFileName = "cloverpit.json"

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
        self.init(applicationSupportRoot: applicationSupportRoot,
                  fileManager: fileManager,
                  fileOperations: .live)
    }

    /// Internal syscall-injectable store. Kept internal so deterministic
    /// snapshot/races can be driven in tests without exposing production API.
    init(applicationSupportRoot: URL, fileManager: FileManager = .default,
         fileOperations: ReceiptFileOperations) {
        self.applicationSupportRoot = applicationSupportRoot
        self.fileManager = fileManager
        self.ops = fileOperations
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
    /// / snapshot-consistency / canonical-byte / semantics violation. This is a
    /// historical-evidence load only; it never promotes the caller's current
    /// acceptance state.
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
        let fileFD = Self.receiptFileName.withCString {
            openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if fileFD < 0 {
            if errno == ENOENT { return .notFound }
            if errno == ELOOP { return .failed(.symlinkDestinationRejected) }
            return .failed(.ioFailure)
        }
        defer { close(fileFD) }

        // Pre-read snapshot from the same opened FD. This is the authority for
        // the whole transaction: an actually-regular file with a bounded size.
        var preStat = stat()
        if ops.fstat(fileFD, &preStat) != 0 { return .failed(.ioFailure) }
        guard (preStat.st_mode & S_IFMT) == S_IFREG else { return .failed(.nonRegularFile) }
        guard preStat.st_size >= 0 else { return .failed(.ioFailure) }
        let expectedSize = Int(preStat.st_size)
        guard expectedSize <= Self.maxReceiptBytes else { return .failed(.oversized) }

        // Read EXACTLY expectedSize bytes from the same FD. Any EOF before the
        // pre-stat size is an inconsistent short read, never `.malformedJSON`.
        var buffer = [UInt8](repeating: 0, count: expectedSize)
        var total = 0
        var eintrRetries = 0
        while total < expectedSize {
            let n = ops.read(fileFD, &buffer[total], expectedSize - total)
            if n < 0 {
                if errno == EINTR {
                    eintrRetries += 1
                    if eintrRetries > Self.maxInterruptedSyscallRetries {
                        return .failed(.ioFailure)
                    }
                    continue
                }
                return .failed(.ioFailure)
            }
            if n == 0 { return .failed(.ioFailure) }
            total += n
            eintrRetries = 0
        }
        // A single probe byte confirms the file did not grow beyond the pre-stat
        // size while we were reading. One bounded retry authority owns the probe
        // from the first attempt through the final result.
        switch probeGrowth(fileFD: fileFD) {
        case .cleanEOF:
            break
        case .growthDetected:
            return .failed(.ioFailure)
        case .ioFailure:
            return .failed(.ioFailure)
        }

        // Post-read snapshot on the same FD. Any change to identity, size, or
        // the most precise available timestamps fails closed.
        var postStat = stat()
        if ops.fstat(fileFD, &postStat) != 0 { return .failed(.ioFailure) }
        guard postStat.st_dev == preStat.st_dev,
              postStat.st_ino == preStat.st_ino,
              postStat.st_size == preStat.st_size,
              postStat.st_mtimespec.tv_sec == preStat.st_mtimespec.tv_sec,
              postStat.st_mtimespec.tv_nsec == preStat.st_mtimespec.tv_nsec,
              postStat.st_ctimespec.tv_sec == preStat.st_ctimespec.tv_sec,
              postStat.st_ctimespec.tv_nsec == preStat.st_ctimespec.tv_nsec else {
            return .failed(.ioFailure)
        }

        let diskBytes = Data(buffer)
        guard let decoded = decodeCanonical(diskBytes) else { return .failed(.malformedJSON) }
        if let failure = acceptedSemanticGate(decoded) { return .failed(failure) }
        if decoded.deterministicJSON != diskBytes { return .failed(.nonCanonicalBytes) }
        return .loaded(decoded)
    }

    /// The single-byte growth probe reads EXACTLY one byte after the exact body
    /// read. A single bounded retry authority owns the probe from the first
    /// attempt through the final result: up to ``maxInterruptedSyscallRetries``
    /// consecutive EINTRs are consumed, and the next consecutive EINTR is a
    /// bounded ioFailure. Clean EOF is a legal terminal state — it is NOT an
    /// ioFailure.
    private func probeGrowth(fileFD: Int32) -> GrowthProbeResult {
        var eintrRetries = 0
        while true {
            var byte: UInt8 = 0
            let n = ops.read(fileFD, &byte, 1)
            if n == 0 { return .cleanEOF }
            if n == 1 { return .growthDetected }
            if n < 0, errno == EINTR {
                eintrRetries += 1
                if eintrRetries > Self.maxInterruptedSyscallRetries {
                    return .ioFailure
                }
                continue
            }
            return .ioFailure
        }
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

    // MARK: - Canonical atomic write (directory-FD-bound POSIX transaction)

    /// Writes the exact canonical bytes through an atomic directory-FD-bound
    /// POSIX transaction. Source and destination for the final `renameat` are
    /// both relative to the SAME opened directory FD; no path is re-resolved.
    /// On any failure ONLY the temp is removed; a pre-existing last-known-good
    /// receipt is never deleted.
    private func writeCanonical(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        let data = receipt.deterministicJSON
        let dirFD = parentPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if dirFD < 0 { return .failed(.ioFailure) }
        defer { close(dirFD) }

        // Unique temp created exclusively in the same directory, relative to the
        // opened directory FD.
        let tempName = ".cloverpit-\(UUID().uuidString).tmp"
        let tempFD = tempName.withCString {
            openat(dirFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                   mode_t(S_IRUSR | S_IWUSR))
        }
        if tempFD < 0 { return .failed(.ioFailure) }

        var writeFailed = false
        var wrote = 0
        var eintrRetries = 0
        while wrote < data.count {
            var count = 0
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                count = ops.write(tempFD, base.advanced(by: wrote), data.count - wrote)
            }
            if count < 0 {
                if errno == EINTR {
                    eintrRetries += 1
                    if eintrRetries > Self.maxInterruptedSyscallRetries {
                        writeFailed = true
                        break
                    }
                    continue
                }
                writeFailed = true
                break
            }
            if count == 0 {
                // Zero progress is a fail-closed condition, never a spin.
                writeFailed = true
                break
            }
            wrote += count
            eintrRetries = 0
        }
        if !writeFailed, fchmod(tempFD, mode_t(S_IRUSR | S_IWUSR)) != 0 {
            writeFailed = true
        }
        if !writeFailed, fsync(tempFD) != 0 {
            writeFailed = true
        }
        _ = close(tempFD)
        if writeFailed {
            // Only the temp is removed — never a pre-existing receipt.
            removeTemp(at: dirFD, name: tempName)
            return .failed(.ioFailure)
        }

        // Atomic install: source and destination are both relative to the same
        // opened directory FD. renameat never follows a destination symlink.
        let renamed = tempName.withCString { t in
            Self.receiptFileName.withCString { d in renameat(dirFD, t, dirFD, d) }
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
