// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Secure receipt writer that only accepts known schema keys.
///
/// MacSteam authentication receipts are restricted to boolean-only values
/// and a fixed set of allowed keys.  Arbitrary dictionaries or free-form
/// log strings cannot be written through this API.
struct SecureReceiptWriter: Sendable {

    /// Schema keys that may appear in a Steam authentication receipt.
    enum Key: String, Sendable, CaseIterable {
        case operation
        case userConfirmedLibraryVisible
        case credentialsAccessed
        case steamGuardAccessed
        case sessionFilesRead
        case accountIdentifierRecorded
    }

    /// A validated receipt with known keys only.
    struct Receipt: Sendable, Equatable {
        let operation: String
        let userConfirmedLibraryVisible: Bool
        let credentialsAccessed: Bool
        let steamGuardAccessed: Bool
        let sessionFilesRead: Bool
        let accountIdentifierRecorded: Bool
    }

    /// Creates a validated receipt, or nil if disallowed keys or non-zero
    /// values are present.
    /// - Parameter entries: Allowed keys only; unknown keys cause rejection.
    static func validate(entries: [String: Any]) -> Receipt? {
        let allowedKeys = Set(Key.allCases.map(\.rawValue))
        let entryKeys = Set(entries.keys)
        guard entryKeys.isSubset(of: allowedKeys) else { return nil }

        guard let operation = entries[Key.operation.rawValue] as? String,
              let userConfirmed = entries[Key.userConfirmedLibraryVisible.rawValue] as? Bool,
              let credentialsAccessed = entries[Key.credentialsAccessed.rawValue] as? Bool,
              let steamGuardAccessed = entries[Key.steamGuardAccessed.rawValue] as? Bool,
              let sessionFilesRead = entries[Key.sessionFilesRead.rawValue] as? Bool,
              let accountIdRecorded = entries[Key.accountIdentifierRecorded.rawValue] as? Bool
        else { return nil }

        // Zero-knowledge compliance: all four booleans must be false
        guard !credentialsAccessed, !steamGuardAccessed, !sessionFilesRead, !accountIdRecorded
        else { return nil }

        return Receipt(
            operation: operation,
            userConfirmedLibraryVisible: userConfirmed,
            credentialsAccessed: credentialsAccessed,
            steamGuardAccessed: steamGuardAccessed,
            sessionFilesRead: sessionFilesRead,
            accountIdentifierRecorded: accountIdRecorded
        )
    }

    /// Serialises a validated receipt to JSON.
    static func encode(_ receipt: Receipt, pretty: Bool = false) -> String {
        let dict: [String: Any] = [
            Key.operation.rawValue: receipt.operation,
            Key.userConfirmedLibraryVisible.rawValue: receipt.userConfirmedLibraryVisible,
            Key.credentialsAccessed.rawValue: receipt.credentialsAccessed,
            Key.steamGuardAccessed.rawValue: receipt.steamGuardAccessed,
            Key.sessionFilesRead.rawValue: receipt.sessionFilesRead,
            Key.accountIdentifierRecorded.rawValue: receipt.accountIdentifierRecorded,
        ]
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: opts) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
