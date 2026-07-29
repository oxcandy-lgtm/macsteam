// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

/// U1R13: SessionPurpose + ActiveSessionReceipt backward compatibility.
struct SessionPurposeTests {

    // MARK: - SessionPurpose

    @Test func testPurposeCases() {
        #expect(SessionPurpose.steamSetup.rawValue == "steamSetup")
        #expect(SessionPurpose.game.rawValue == "game")
    }

    @Test func testPurposeCodable() throws {
        let encoded = try JSONEncoder().encode(SessionPurpose.steamSetup)
        let decoded = try JSONDecoder().decode(SessionPurpose.self, from: encoded)
        #expect(decoded == .steamSetup)
    }

    // MARK: - ActiveSessionReceipt backward compat

    @Test func testOldReceiptDecodesAsGame() throws {
        // A receipt JSON without the 'purpose' field (pre-U1R13 format)
        let oldJSON = """
        {
            "sessionID": "00000000-0000-0000-0000-000000000001",
            "recipeID": "test",
            "runtimeID": "system-wine",
            "prefixID": "abc123def456",
            "rootPID": 12345,
            "startedAt": 725356800,
            "state": "runningUnknown"
        }
        """.data(using: .utf8)!

        let receipt = try JSONDecoder().decode(ActiveSessionReceipt.self, from: oldJSON)
        #expect(receipt.purpose == .game, "Old receipt without purpose must decode as .game")
        #expect(receipt.recipeID == "test")
        #expect(receipt.rootPID == 12345)
    }

    @Test func testNewReceiptWithSteamSetup() throws {
        let newJSON = """
        {
            "sessionID": "00000000-0000-0000-0000-000000000002",
            "recipeID": "test",
            "runtimeID": "system-wine",
            "prefixID": "abc123def789",
            "rootPID": 54321,
            "startedAt": 725356800,
            "state": "runningUnknown",
            "purpose": "steamSetup"
        }
        """.data(using: .utf8)!

        let receipt = try JSONDecoder().decode(ActiveSessionReceipt.self, from: newJSON)
        #expect(receipt.purpose == .steamSetup)
        #expect(receipt.rootPID == 54321)
    }

    @Test func testNewReceiptWithGame() throws {
        let newJSON = """
        {
            "sessionID": "00000000-0000-0000-0000-000000000003",
            "recipeID": "test",
            "runtimeID": "system-wine",
            "prefixID": "xyz789abc123",
            "rootPID": 99999,
            "startedAt": 725356800,
            "state": "runningVisible",
            "purpose": "game"
        }
        """.data(using: .utf8)!

        let receipt = try JSONDecoder().decode(ActiveSessionReceipt.self, from: newJSON)
        #expect(receipt.purpose == .game)
        #expect(receipt.state == .runningVisible)
    }
}
