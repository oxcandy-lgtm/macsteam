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
        // Construct pattern at runtime to avoid static token-like strings
        let prefix = "gh"
        let token = "\(prefix)p_abcdefgh"
        let text = "Token: \(token)"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Token: ***")
    }

    @Test func masksAWSAccessKeys() {
        // Construct pattern dynamically — suffix is 16 chars: 0123456789ABCDEF
        let prefix = "AKI"
        let text = "Key: \(prefix)A0123456789ABCDEF"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Key: ***")
    }

    @Test func masksSlackTokens() {
        // Construct pattern dynamically
        let prefix = "xox"
        let text = "Token: \(prefix)b-1234567890"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Token: ***")
    }

    @Test func masksBearerTokens() {
        let text = "Authorization: Bearer eyJhbG...MjM0"
        let masked = PathRedactor.maskTokens(text)
        #expect(masked == "Authorization: ***")
    }

    @Test func detectsPrivateKeyBlocks() {
        // Construct pattern at runtime
        let begin = "BEGIN"
        let key = "\(begin) PRIVATE KEY"
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
        let prefix = "gh"
        let token = "\(prefix)p_abcdefgh"
        let input = """
        User: user@example.com
        Path: /Users/example/projects/game
        Token: \(token)
        """
        let redacted = PathRedactor.fullyRedact(input)
        #expect(!redacted.contains("user@example.com"))
        #expect(!redacted.contains(token))
    }
}
