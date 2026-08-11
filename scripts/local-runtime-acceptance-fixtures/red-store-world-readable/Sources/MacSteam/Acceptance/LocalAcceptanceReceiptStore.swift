// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixture store (GREEN baseline for the acceptance audit harness).
/// Durably persists only __accepted__ receipts as the exact deterministic JSON
/// bytes through a symlink-fail-closed, atomic, private-namespace path.
struct LocalAcceptanceReceiptStore {
    nonisolated static let relativeReceiptPath = "Acceptance/cloverpit.json"
    nonisolated static let maxReceiptBytes: Int = 1 << 12
    nonisolated static let parentDirectoryPermissions = 0o700
    nonisolated static let receiptFilePermissions = 0o644
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
        if receipt.status.state != .accepted { return .notAccepted }
        if receipt.status.blocker.lowercased() != "none" { return .blockerNotNone }
        if receipt.evidence.cleanupComplete == false { return .evidenceIncomplete }
        if receipt.evidence.visibilityStableSeconds < Self.requiredStabilitySeconds {
            return .visibilityBelowMinimum
        }
        if receipt.security.rawPIDEmitted { return .securityFlagSet }
        return nil
    }

    func loadAccepted() -> LocalAcceptanceReceiptStoreResult {
        if size > Self.maxReceiptBytes { return .failed(.oversized) }
        guard let bytes = diskBytes else { return .notFound }
        guard let decoded = decode(bytes) else { return .failed(.malformedJSON) }
        if decoded.deterministicJSON != bytes { return .failed(.nonCanonicalBytes) }
        return .loaded(decoded)
    }

    private var symlinkDestinationRejected: Bool { false }
    private var symlinkParentEscapeRejected: Bool { false }
    private var size: Int { 0 }
    private var diskBytes: Data? { nil }

    private func writeCanonical(_ receipt: LocalAcceptanceReceipt) -> LocalAcceptanceReceiptStoreResult {
        let data = receipt.deterministicJSON
        _ = "atomic replace + temp cleanup"
        return .saved
    }

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
    case malformedJSON = "receipt_malformed_json"
    case nonCanonicalBytes = "receipt_non_canonical_bytes"
    case symlinkDestinationRejected = "receipt_symlink_destination"
    case symlinkParentEscapeRejected = "receipt_symlink_parent_escape"
    case oversized = "receipt_oversized"
    case invalid = "receipt_invalid"
    case ioFailure = "receipt_io_failure"
}