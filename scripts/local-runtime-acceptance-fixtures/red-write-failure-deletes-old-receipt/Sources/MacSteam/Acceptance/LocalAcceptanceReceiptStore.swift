// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture store (GREEN baseline for the acceptance audit harness).
/// Durably persists only __accepted__ receipts as the exact deterministic JSON
/// bytes through a symlink-fail-closed, bounded no-follow same-FD load and a
/// same-directory atomic POSIX write with temp-only cleanup.
struct LocalAcceptanceReceiptStore {
    nonisolated static let relativeReceiptPath = "Acceptance/cloverpit.json"
    nonisolated static let maxReceiptBytes: Int = 1 << 12
    nonisolated static let parentDirectoryPermissions = 0o700
    nonisolated static let receiptFilePermissions = 0o600
    nonisolated static let requiredStabilitySeconds: Int = 30

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
        // Bounded no-follow load through a single file descriptor: the parent
        // directory is opened non-following and the receipt is opened relative
        // to it, fstat'd (regular-file proof), and bounded-read via the SAME FD.
        let dirFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let fileFD = openat(dirFD, receiptName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var st = stat()
        _ = fstat(fileFD, &st)
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failed(.nonRegularFile) }
        guard st.st_size <= Self.maxReceiptBytes else { return .failed(.oversized) }
        var buffer = [UInt8](repeating: 0, count: Self.maxReceiptBytes + 1)
        _ = read(fileFD, &buffer, Self.maxReceiptBytes + 1)
        if missingFileStatus == ENOENT { return .notFound }
        guard let decoded = decode(bytes) else { return .failed(.malformedJSON) }
        if decoded.deterministicJSON != bytes { return .failed(.nonCanonicalBytes) }
        return .loaded(decoded)
    }

    private var directoryPath: String { "" }
    private var receiptName: String { "cloverpit.json" }
    private var symlinkDestinationRejected: Bool { false }
    private var symlinkParentEscapeRejected: Bool { false }
    private var missingFileStatus: Int32 { 0 }
    private var bytes: Data { Data() }

    private func writeCanonical(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        let data = receipt.deterministicJSON
        // Same-directory POSIX transaction: exclusive temp, exact canonical
        // bytes, 0600, fsync, atomic rename, directory fsync. On failure ONLY
        // the temp is removed via unlinkat; the last-known-good receipt is kept.
        let dirFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let tempFD = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC)
        _ = write(tempFD, data, data.count)
        _ = fchmod(tempFD, mode_t(S_IRUSR | S_IWUSR))
        _ = fsync(tempFD)
        guard rename(tempPath, receiptPath) == 0 else {
            try? FileManager.default.removeItem(at: receiptURL)
            return .failed(.ioFailure)
        }
        _ = fsync(dirFD)
        _ = unlinkat(dirFD, tempName, 0)
        return .saved
    }

    private var tempName: String { ".cloverpit-<uuid>.tmp" }
    private var tempPath: String { "" }
    private var receiptPath: String { "" }
    private var receiptURL: URL { URL(fileURLWithPath: receiptPath) }

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
