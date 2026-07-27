// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MacSteam

struct SecureReceiptWriterTests {

    // MARK: - Creation

    @Test func testMakeValidReceipt() {
        let receipt = SecureReceiptWriter.make(
            operation: .userConfirmedSteamLibrary,
            userConfirmedLibraryVisible: true
        )
        #expect(receipt.operation == .userConfirmedSteamLibrary)
        #expect(receipt.userConfirmedLibraryVisible == true)
    }

    @Test func testAllCredentialFlagsAreFalse() {
        let receipt = SecureReceiptWriter.make(
            operation: .cloverPitManifestDetected,
            userConfirmedLibraryVisible: false
        )
        #expect(receipt.credentialsAccessed == false)
        #expect(receipt.steamGuardAccessed == false)
        #expect(receipt.sessionFilesRead == false)
        #expect(receipt.accountIdentifierRecorded == false)
    }

    // MARK: - No free-form strings

    @Test func testNoArbitraryDictionaryAPI() {
        // The old validate(entries:) API must not exist.
        // Only typed SecureReceiptOperation values are accepted.
        #expect(SecureReceiptOperation.allCases.count == 5)
    }

    // MARK: - Encoding

    @Test func testEncodeJson() {
        let receipt = SecureReceiptWriter.make(
            operation: .userConfirmedSteamLibrary,
            userConfirmedLibraryVisible: true
        )
        let json = SecureReceiptWriter.encode(receipt)
        #expect(json.contains("\"operation\""))
        #expect(json.contains("\"userConfirmedLibraryVisible\""))
        #expect(json.contains("true"))
    }

    @Test func testEncodeDoesNotContainCredentials() {
        let receipt = SecureReceiptWriter.make(
            operation: .cloverPitLaunchSubmitted,
            userConfirmedLibraryVisible: false
        )
        let json = SecureReceiptWriter.encode(receipt)
        #expect(json.contains("\"credentialsAccessed\":false"))
        #expect(!json.contains("true"))
    }

    @Test func testDecodeRoundTrip() {
        let original = SecureReceiptWriter.make(
            operation: .cloverPitWindowConfirmed,
            userConfirmedLibraryVisible: true
        )
        let json = SecureReceiptWriter.encode(original)
        let decoded = SecureReceiptWriter.decode(json)
        #expect(decoded != nil)
        #expect(decoded?.operation == .cloverPitWindowConfirmed)
        #expect(decoded?.userConfirmedLibraryVisible == true)
    }
}
