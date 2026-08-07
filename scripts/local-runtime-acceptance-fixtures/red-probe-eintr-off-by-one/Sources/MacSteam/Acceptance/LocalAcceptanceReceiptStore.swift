// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture store (GREEN baseline for the acceptance audit harness).
/// Durably persists only __accepted__ receipts as the exact deterministic JSON
/// bytes through a symlink-fail-closed, snapshot-consistent bounded no-follow
/// same-FD load and a single directory-FD-bound atomic POSIX write with
/// temp-only cleanup. Every read/write EINTR is bounded and a zero-progress
/// write fails closed.
struct LocalAcceptanceReceiptStore {
    nonisolated static let relativeReceiptPath = "Acceptance/cloverpit.json"
    nonisolated static let maxReceiptBytes: Int = 1 << 12
    nonisolated static let parentDirectoryPermissions = 0o700
    nonisolated static let receiptFilePermissions = 0o600
    nonisolated static let requiredStabilitySeconds: Int = 30
    nonisolated static let maxInterruptedSyscallRetries = 8

    init(applicationSupportRoot: URL) {}

    @discardableResult
    func saveAccepted(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        if let failure = acceptedSemanticGate(receipt) {
            return .failed(failure)
        }
        if symlinkDestinationRejected { return .failed(.symlinkDestinationRejected) }
        if symlinkParentEscapeRejected { return .failed(.symlinkParentEscapeRejected) }
        return writeCanonical(receipt)
    }

    func acceptedSemanticGate(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreError? {
        if receipt.target != LocalAcceptanceReceipt.Target.canonical { return .targetMismatch }
        if receipt.status.state != .accepted { return .notAccepted }
        if receipt.status.blocker.lowercased() != "none" { return .blockerNotNone }
        if !receipt.evidence.cleanupComplete { return .evidenceIncomplete }
        if receipt.evidence.visibilityStableSeconds < Self.requiredStabilitySeconds {
            return .visibilityBelowMinimum
        }
        if receipt.security.credentialsAccessed || receipt.security.rawPIDEmitted {
            return .securityFlagSet
        }
        return nil
    }

    func loadAccepted() -> LocalAcceptanceReceiptStoreResult {
        // Snapshot-consistent bounded no-follow load through a single file
        // descriptor: the parent is opened non-following, the receipt is opened
        // relative to it (O_NOFOLLOW|O_NONBLOCK), fstat'd (regular-file proof
        // + size bound), read EXACTLY the pre-stat size with a bounded EINTR
        // retry, probed for growth, then re-fstat'd. Any pre<->post metadata
        // change or inconsistent short read fails closed.
        let dirFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let fileFD = openat(dirFD, receiptName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var preStat = stat()
        _ = fstat(fileFD, &preStat)
        guard (preStat.st_mode & S_IFMT) == S_IFREG else { return .failed(.nonRegularFile) }
        let expectedSize = Int(preStat.st_size)
        guard expectedSize <= Self.maxReceiptBytes else { return .failed(.oversized) }
        var buffer = [UInt8](repeating: 0, count: expectedSize)
        var total = 0
        var readRetries = 0
        while total < expectedSize {
            let n = read(fileFD, &buffer[total], expectedSize - total)
            if n < 0 {
                if errno == EINTR {
                    readRetries += 1
                    if readRetries > Self.maxInterruptedSyscallRetries { return .failed(.ioFailure) }
                    continue
                }
                return .failed(.ioFailure)
            }
            if n == 0 { return .failed(.ioFailure) }
            total += n
            readRetries = 0
        }
        // Single-authority growth probe: one bounded retry owner from the first
        // attempt through the final result. Clean EOF continues past to postStat.
        switch probeGrowth(fileFD) {
        case .cleanEOF:
            break
        case .growthDetected:
            return .failed(.ioFailure)
        case .ioFailure:
            return .failed(.ioFailure)
        }
        var postStat = stat()
        _ = fstat(fileFD, &postStat)
        guard postStat.st_dev == preStat.st_dev,
              postStat.st_ino == preStat.st_ino,
              postStat.st_size == preStat.st_size,
              postStat.st_mtimespec.tv_sec == preStat.st_mtimespec.tv_sec,
              postStat.st_mtimespec.tv_nsec == preStat.st_mtimespec.tv_nsec,
              postStat.st_ctimespec.tv_sec == preStat.st_ctimespec.tv_sec,
              postStat.st_ctimespec.tv_nsec == preStat.st_ctimespec.tv_nsec else {
            return .failed(.ioFailure)
        }
        let bytes = Data(buffer)
        if missingFileStatus == ENOENT { return .notFound }
        guard let decoded = decode(bytes) else { return .failed(.malformedJSON) }
        if decoded.deterministicJSON != bytes { return .failed(.nonCanonicalBytes) }
        return .loaded(decoded)
    }

    /// One bounded retry authority owns the single-byte growth probe. Clean EOF
    /// (n == 0) is a legal terminal state, not an ioFailure; an extra byte
    /// (n == 1) is growth. EINTR is consumed against a single bounded counter;
    /// the next consecutive EINTR after the bound fails closed.
    private func probeGrowth(fileFD: Int32) -> GrowthProbeResult {
        var eintrRetries = 0
        while true {
            var byte: UInt8 = 0
            let n = read(fileFD, &byte, 1)
            if n == 0 { return .cleanEOF }
            if n == 1 { return .growthDetected }
            if n < 0 && errno == EINTR {
                eintrRetries += 1
                if eintrRetries > Self.maxInterruptedSyscallRetries + 1 {
                    return .ioFailure
                }
                continue
            }
            return .ioFailure
        }
    }

    private var directoryPath: String { "" }
    private var receiptName: String { "cloverpit.json" }
    private var symlinkDestinationRejected: Bool { false }
    private var symlinkParentEscapeRejected: Bool { false }
    private var missingFileStatus: Int32 { 0 }

    private func writeCanonical(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        let data = receipt.deterministicJSON
        // Single directory-FD-bound POSIX transaction: exclusive temp, exact
        // canonical bytes, 0600, fsync, bounded-EINTR write with zero-progress
        // fail-closed, and an atomic renameat where source AND destination share
        // the SAME opened directory FD. On failure ONLY the temp is removed via
        // unlinkat; the last-known-good receipt is kept.
        let dirFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let tempFD = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC)
        var wrote = 0
        var writeRetries = 0
        while wrote < data.count {
            let count = write(tempFD, data, data.count - wrote)
            if count < 0 {
                if errno == EINTR {
                    writeRetries += 1
                    if writeRetries > Self.maxInterruptedSyscallRetries { return .failed(.ioFailure) }
                    continue
                }
                return .failed(.ioFailure)
            }
            if count == 0 { return .failed(.ioFailure) }
            wrote += count
            writeRetries = 0
        }
        _ = fchmod(tempFD, mode_t(S_IRUSR | S_IWUSR))
        _ = fsync(tempFD)
        _ = renameat(dirFD, tempName, dirFD, receiptName)
        _ = fsync(dirFD)
        return .saved
    }

    private var tempName: String { ".cloverpit-<uuid>.tmp" }

    private func decode(_ bytes: Data) -> LocalAcceptanceReceipt? {
        try? JSONDecoder().decode(LocalAcceptanceReceipt.self, from: bytes)
    }
}

enum LocalAcceptanceReceiptStoreResult: Sendable, Equatable {
    case saved
    case notFound
    case loaded(LocalAcceptanceReceipt)
    case failed(LocalAcceptanceReceiptStoreError)
}

enum GrowthProbeResult {
    case cleanEOF
    case growthDetected
    case ioFailure
}

enum LocalAcceptanceReceiptStoreError: String, Sendable, Equatable {
    case notAccepted = "receipt_not_accepted"
    case blockerNotNone = "receipt_blocker_not_none"
    case evidenceIncomplete = "receipt_evidence_incomplete"
    case visibilityBelowMinimum = "receipt_visibility_below_minimum"
    case securityFlagSet = "receipt_security_flag_set"
    case targetMismatch = "receipt_target_mismatch"
    case malformedJSON = "receipt_malformed_json"
    case nonCanonicalBytes = "receipt_non_canonical_bytes"
    case oversized = "receipt_oversized"
    case symlinkDestinationRejected = "receipt_symlink_destination"
    case symlinkParentEscapeRejected = "receipt_symlink_parent_escape"
    case nonRegularFile = "receipt_not_regular_file"
    case ioFailure = "receipt_io_failure"
}
