// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct OperationReceiptTests {

    @Test func testReceiptCreation() {
        let now = Date()
        let receipt = OperationReceipt(
            schemaVersion: 1,
            operation: .createPrefix,
            recipeId: "cloverpit",
            runtimeId: "managed-wine",
            runtimeManifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
            recipeHash: "deadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabe",
            startedAt: now,
            finishedAt: now.addingTimeInterval(5.0),
            result: .success,
            personalPathOutput: false,
            credentialOutput: false
        )

        #expect(receipt.schemaVersion == 1)
        #expect(receipt.operation == .createPrefix)
        #expect(receipt.recipeId == "cloverpit")
        #expect(receipt.runtimeId == "managed-wine")
        #expect(receipt.result == .success)
        #expect(receipt.personalPathOutput == false)
        #expect(receipt.credentialOutput == false)
        #expect(receipt.startedAt == now)
        #expect(receipt.finishedAt > now)
    }

    @Test func testNoCredentialsInOutput() {
        let now = Date()
        let receipt = OperationReceipt(
            operation: .launchGame,
            recipeId: "test",
            startedAt: now,
            finishedAt: now,
            result: .success,
            credentialOutput: false
        )

        #expect(receipt.credentialOutput == false)
        #expect(receipt.personalPathOutput == false)
    }

    @Test func testReceiptWithCredentialsFlagged() {
        let now = Date()
        let receipt = OperationReceipt(
            operation: .installRuntime,
            startedAt: now,
            finishedAt: now,
            result: .success,
            credentialOutput: true
        )

        #expect(receipt.credentialOutput == true)
    }

    @Test func testAllOperationKinds() {
        let now = Date()
        let kinds: [OperationKind] = [
            .createPrefix,
            .destroyPrefix,
            .installRuntime,
            .removeRuntime,
            .installSteam,
            .launchGame,
            .repairPrefix,
            .snapshotPrefix,
        ]

        for kind in kinds {
            let receipt = OperationReceipt(
                operation: kind,
                startedAt: now,
                finishedAt: now,
                result: .success
            )
            #expect(receipt.operation == kind)
        }
    }

    @Test func testAllOperationResults() {
        let now = Date()
        let results: [OperationResult] = [
            .success,
            .failure,
            .cancelled,
            .dryRun,
        ]

        for result in results {
            let receipt = OperationReceipt(
                operation: .launchGame,
                startedAt: now,
                finishedAt: now,
                result: result
            )
            #expect(receipt.result == result)
        }
    }

    @Test func testReceiptRoundTripJSON() throws {
        let now = Date()
        let receipt = OperationReceipt(
            operation: .createPrefix,
            recipeId: "test-game",
            startedAt: now,
            finishedAt: now.addingTimeInterval(3.0),
            result: .success,
            personalPathOutput: true,
            credentialOutput: false
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(receipt)
        let decoded = try decoder.decode(OperationReceipt.self, from: data)

        #expect(decoded.operation == receipt.operation)
        #expect(decoded.recipeId == receipt.recipeId)
        #expect(decoded.result == receipt.result)
        #expect(decoded.personalPathOutput == receipt.personalPathOutput)
        #expect(decoded.credentialOutput == receipt.credentialOutput)
    }
}
