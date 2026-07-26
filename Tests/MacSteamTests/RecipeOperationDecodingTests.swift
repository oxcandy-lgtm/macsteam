// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RecipeOperationDecodingTests {

    // Attempt to decode runShell — this operation kind is forbidden in U1
    @Test func testRunShellFailsToDecode() throws {
        let json = """
        {
            "kind": "runShell",
            "value": "echo hello"
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    // Attempt to decode runSudo — forbidden
    @Test func testRunSudoFailsToDecode() throws {
        let json = """
        {
            "kind": "runSudo",
            "value": "whoami"
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    // Attempt to decode deleteHostPath — forbidden
    @Test func testDeleteHostPathFailsToDecode() throws {
        let json = """
        {
            "kind": "deleteHostPath",
            "value": "/tmp/foo"
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    // Attempt to decode downloadArbitraryURL — forbidden
    @Test func testDownloadArbitraryURLFailsToDecode() throws {
        let json = """
        {
            "kind": "downloadArbitraryURL",
            "value": "https://example.com/payload"
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    // Verify that a kind with completely wrong type for value also fails
    @Test func testWrongValueTypeFails() throws {
        let json = """
        {
            "kind": "setWindowsVersion",
            "value": 42
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    // Verify that totally empty JSON fails
    @Test func testEmptyJSONFails() throws {
        let data = try #require("{}".data(using: .utf8))
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }
}
