// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct PathRedactorTests {

    @Test func redactsHomeDirectory() {
        let realHome = NSHomeDirectory()
        let path = "\(realHome)/Library/Application Support/MacSteam/logs"
        let redacted = PathRedactor.redactPath(path)
        #expect(redacted == "$HOME/Library/Application Support/MacSteam/logs")
        #expect(!redacted.contains(realHome))
    }

    @Test func masksEmailAddresses() {
        let text = "Contact me at user@example.com for help."
        let masked = PathRedactor.maskEmails(text)
        #expect(masked == "Contact me at ***@***.*** for help.")
    }

    @Test func masksGitHubTokens() {
        let text = "Token: ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Token: ***")
    }

    @Test func masksAWSAccessKeys() {
        let text = "Key: AKIAIOSFODNN7EXAMPLE"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Key: ***")
    }

    @Test func masksSlackTokens() {
        let text = "Token: xoxb-1234567890-1234567890123-abcdefghijklm"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Token: ***")
    }

    @Test func masksBearerTokens() {
        let text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Authorization: ***")
    }

    @Test func detectsPrivateKeyBlocks() {
        let key = "-----BEGIN PRIVATE KEY-----\nABCDEFGH==\n-----END PRIVATE KEY-----"
        #expect(PathRedactor.containsPrivateKey(key))
    }

    @Test func rejectsNonKeyContent() {
        #expect(!PathRedactor.containsPrivateKey("Just some text"))
    }

    @Test func masksHostnames() {
        let text = "Connected to server.local"
        let masked = PathRedactor.maskHostnames(text)
        #expect(masked == "Connected to *.redacted")
    }

    @Test func fullyRedactsCombinedContent() {
        let input = """
        User: alice@example.com
        Path: /Users/alice/projects/game
        Token: ghp_abcdefgh
        """
        let redacted = PathRedactor.fullyRedact(input)
        #expect(!redacted.contains("alice@example.com"))
        #expect(!redacted.contains("ghp_abcdefgh"))
    }
}
