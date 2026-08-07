// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
///   * Load is fail-closed and bounded: max file size → canonical decode →
///     accepted semantic validation → deterministic re-encode → disk bytes ==
///     canonical bytes. Unknown fields, extra payload and non-canonical
///     serialization all fail closed (not cryptographic tamper proof).
///   * Filesystem safety: private (0700) parent dir, `0600` receipt, temp write
///     in the same directory, atomic replace, temp cleanup on success and
///     failure, and symlink destination / symlink parent-escape rejection.
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
    /// / canonical-byte / semantics violation. This is a historical-evidence load
    /// only; it never promotes the caller's current acceptance state.
    func loadAccepted() -> LocalAcceptanceReceiptStoreResult {
        if let failure = destinationAuditFailure() { return .failed(failure) }
        if let size = fileSize(at: receiptPath), size > Self.maxReceiptBytes {
            return .failed(.oversized)
        }
        guard let diskBytes = try? Data(contentsOf: receiptURL) else { return .notFound }
        if diskBytes.count > Self.maxReceiptBytes { return .failed(.oversized) }

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

    private func destinationAuditFailure() -> LocalAcceptanceReceiptStoreError? {
        guard fileManager.fileExists(atPath: receiptPath) else { return nil }
        if isSymlink(at: receiptPath) { return .symlinkDestinationRejected }
        if isSymlink(at: parentPath) { return .symlinkParentEscapeRejected }
        if !isRegularFile(at: receiptPath) { return .nonRegularFile }
        return nil
    }

    private func isSymlink(at path: String) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func isRegularFile(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private func fileSize(at path: String) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? Int)
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

    // MARK: - Canonical atomic write

    private func writeCanonical(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        let data = receipt.deterministicJSON
        let tempURL = acceptanceRoot.appendingPathComponent(".cloverpit-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: [])
            try fileManager.setAttributes([.posixPermissions: Self.receiptFilePermissions],
                                          ofItemAtPath: tempURL.path)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return .failed(.ioFailure)
        }
        do {
            _ = try fileManager.replaceItemAt(receiptURL, withItemAt: tempURL,
                                              backupItemName: nil,
                                              options: [.usingNewMetadataOnly])
            try? fileManager.removeItem(at: tempURL)
            return .saved
        } catch {
            try? fileManager.removeItem(at: tempURL)
            try? fileManager.removeItem(at: receiptURL)
            return .failed(.ioFailure)
        }
    }
}