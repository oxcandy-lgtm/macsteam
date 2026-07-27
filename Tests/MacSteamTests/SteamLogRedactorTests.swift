// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SecureSteamLoggerTests {

    // MARK: - No free-form strings

    @Test func testNoFreeFormStringLoggingAPI() {
        #expect(SteamLogRedactor.deprecated)
    }

    // MARK: - Logger events

    @Test func testRecordEvent() async {
        let logger = SecureSteamLogger()
        await logger.record(.libraryVisibilityConfirmed)
        let count = await logger.eventCount()
        #expect(count == 1)
    }

    @Test func testRecordMultipleEvents() async {
        let logger = SecureSteamLogger()
        await logger.record(.steamProcessObserved)
        await logger.record(.cloverPitManifestDetected)
        await logger.record(.launchSubmitted)
        let count = await logger.eventCount()
        #expect(count == 3)
    }

    @Test func testSensitiveInputRejection() async {
        let logger = SecureSteamLogger()
        await logger.record(.sensitiveInputRejected(.password))
        await logger.record(.sensitiveInputRejected(.steamGuard))
        let summary = await logger.summary()
        #expect(summary.contains("sensitive input"))
        #expect(summary.contains("password"))
        #expect(summary.contains("steamGuard"))
    }

    @Test func testResetClearsEvents() async {
        let logger = SecureSteamLogger()
        await logger.record(.libraryVisibilityConfirmed)
        await logger.reset()
        let count = await logger.eventCount()
        #expect(count == 0)
    }

    // MARK: - Path authorisation via SteamPathDenylist

    @Test func testLoginusersUrlDenied() {
        let url = URL(fileURLWithPath: "/Steam/config/loginusers.vdf")
        let auth = SteamPathDenylist.authorizeRead(url)
        #expect(auth == .deny)
    }

    @Test func testAppmanifestUrlAllowed() {
        let url = URL(fileURLWithPath: "/Steam/steamapps/appmanifest_3314790.acf")
        let auth = SteamPathDenylist.authorizeRead(url)
        if case .allowManifest = auth {
            Bool(true)
        } else {
            Issue.record("Expected allowManifest, got \(auth)")
        }
    }

    @Test func testCloverpitExeAllowed() {
        let url = URL(fileURLWithPath: "/Steam/steamapps/common/CloverPit/CloverPit.exe")
        let auth = SteamPathDenylist.authorizeRead(url)
        if case .allowExecutableMetadata = auth {
            Bool(true)
        } else {
            Issue.record("Expected allowExecutableMetadata, got \(auth)")
        }
    }

    @Test func testUnknownPathDenied() {
        let url = URL(fileURLWithPath: "/some/unknown/path")
        let auth = SteamPathDenylist.authorizeRead(url)
        #expect(auth == .deny)
    }
}
