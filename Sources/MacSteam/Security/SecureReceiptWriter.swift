// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixed set of operations that may appear in a secure receipt.
/// Free-form strings are never accepted.
enum SecureReceiptOperation: String, Codable, Sendable, CaseIterable {
    case userConfirmedSteamLibrary
    case cloverPitManifestDetected
    case cloverPitExecutableDetected
    case cloverPitLaunchSubmitted
    case cloverPitWindowConfirmed
}

/// A secure receipt with known operations only.
///
/// All credential flags are hard-coded to `false` at the type level —
/// callers cannot set them to any other value. Receipts containing
/// non-zero credential flags cannot be constructed through this API.
struct Receipt: Codable, Sendable, Equatable {
    let operation: SecureReceiptOperation
    let userConfirmedLibraryVisible: Bool
    let credentialsAccessed: Bool
    let steamGuardAccessed: Bool
    let sessionFilesRead: Bool
    let accountIdentifierRecorded: Bool

    fileprivate init(
        operation: SecureReceiptOperation,
        userConfirmedLibraryVisible: Bool
    ) {
        self.operation = operation
        self.userConfirmedLibraryVisible = userConfirmedLibraryVisible
        self.credentialsAccessed = false
        self.steamGuardAccessed = false
        self.sessionFilesRead = false
        self.accountIdentifierRecorded = false
    }
}

/// Secure receipt writer that only accepts typed operations.
///
/// No arbitrary dictionaries, no free-form strings, no credential values.
struct SecureReceiptWriter: Sendable {

    /// Creates a validated receipt with all credential flags forced to false.
    /// - Returns: A receipt, or `nil` if the operation is not recognised
    ///   (should never happen with the typed enum).
    static func make(
        operation: SecureReceiptOperation,
        userConfirmedLibraryVisible: Bool
    ) -> Receipt {
        Receipt(
            operation: operation,
            userConfirmedLibraryVisible: userConfirmedLibraryVisible
        )
    }

    /// Serialises a validated receipt to JSON.
    static func encode(_ receipt: Receipt, pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        guard let data = try? encoder.encode(receipt) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decodes a receipt from JSON. Returns nil on invalid input.
    static func decode(_ json: String) -> Receipt? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }
}
