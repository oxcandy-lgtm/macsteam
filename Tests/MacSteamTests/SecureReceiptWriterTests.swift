// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SecureReceiptWriterTests {

    // MARK: - Validation

    @Test func testValidateRejectsUnknownKeys() {
        let entries: [String: Any] = [
            "operation": "steam-user-confirmation",
            "userConfirmedLibraryVisible": true,
            "credentialsAccessed": false,
            "steamGuardAccessed": false,
            "sessionFilesRead": false,
            "accountIdentifierRecorded": false,
            "secret_key": "should be rejected",
        ]
        #expect(SecureReceiptWriter.validate(entries: entries) == nil)
    }

    @Test func testValidateAcceptsValidReceipt() {
        let entries: [String: Any] = [
            "operation": "steam-user-confirmation",
            "userConfirmedLibraryVisible": true,
            "credentialsAccessed": false,
            "steamGuardAccessed": false,
            "sessionFilesRead": false,
            "accountIdentifierRecorded": false,
        ]
        let receipt = SecureReceiptWriter.validate(entries: entries)
        #expect(receipt != nil)
        #expect(receipt?.operation == "steam-user-confirmation")
        #expect(receipt?.userConfirmedLibraryVisible == true)
    }

    @Test func testValidateRejectsCredentialsAccessed() {
        let entries: [String: Any] = [
            "operation": "test",
            "userConfirmedLibraryVisible": true,
            "credentialsAccessed": true,
            "steamGuardAccessed": false,
            "sessionFilesRead": false,
            "accountIdentifierRecorded": false,
        ]
        #expect(SecureReceiptWriter.validate(entries: entries) == nil)
    }

    @Test func testValidateRejectsMissingKeys() {
        let entries: [String: Any] = [
            "operation": "test",
            "userConfirmedLibraryVisible": true,
        ]
        #expect(SecureReceiptWriter.validate(entries: entries) == nil)
    }

    // MARK: - Encoding

    @Test func testEncodeJson() {
        let receipt = SecureReceiptWriter.Receipt(
            operation: "test",
            userConfirmedLibraryVisible: true,
            credentialsAccessed: false,
            steamGuardAccessed: false,
            sessionFilesRead: false,
            accountIdentifierRecorded: false
        )
        let json = SecureReceiptWriter.encode(receipt)
        #expect(json.contains("\"operation\":\"test\""))
        #expect(json.contains("\"userConfirmedLibraryVisible\":true"))
        #expect(json.contains("\"credentialsAccessed\":false"))
    }

    @Test func testEncodeJsonContainsOnlyAllowedKeys() {
        let receipt = SecureReceiptWriter.Receipt(
            operation: "steam-user-confirmation",
            userConfirmedLibraryVisible: true,
            credentialsAccessed: false,
            steamGuardAccessed: false,
            sessionFilesRead: false,
            accountIdentifierRecorded: false
        )
        let json = SecureReceiptWriter.encode(receipt)
        #expect(!json.contains("secret"))
        #expect(!json.contains("password"))
        #expect(!json.contains("token"))
    }
}
