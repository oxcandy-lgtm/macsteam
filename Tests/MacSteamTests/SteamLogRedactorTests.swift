// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SteamLogRedactorTests {

    // MARK: - Clean results

    @Test func testCleanInputReturnsClean() {
        let result = SteamLogRedactor.redact("hello world")
        #expect(!result.applied)
        #expect(result.category == nil)
    }

    @Test func testForceD3d11ArgIsClean() {
        let result = SteamLogRedactor.redact("--force-d3d11")
        #expect(!result.applied)
    }

    // MARK: - Sensitive categories

    @Test func testSteamGuardRejected() {
        let result = SteamLogRedactor.redact("SteamGuard code received")
        #expect(result.applied)
        #expect(result.category == .steamGuard)
    }

    @Test func testPasswordRejected() {
        let result = SteamLogRedactor.redact("password entered")
        #expect(result.applied)
        #expect(result.category == .password)
    }

    @Test func testSessionTokenRejected() {
        let result = SteamLogRedactor.redact("session token value")
        #expect(result.applied)
    }

    @Test func testCookieRejected() {
        let result = SteamLogRedactor.redact("cookie data")
        #expect(result.applied)
        #expect(result.category == .cookie)
    }

    @Test func testDumpFileRejected() {
        let result = SteamLogRedactor.redact("crash.dmp")
        #expect(result.applied)
        #expect(result.category == .crashMemoryDump)
    }

    @Test func testSsfnRejected() {
        let result = SteamLogRedactor.redact("ssfn_secret_file")
        #expect(result.applied)
        #expect(result.category == .machineAuthorization)
    }

    // MARK: - URL redaction

    @Test func testLoginusersUrlRejected() {
        let url = URL(fileURLWithPath: "/Steam/config/loginusers.vdf")
        let result = SteamLogRedactor.redactURL(url)
        #expect(result.applied)
    }

    @Test func testAppmanifestUrlAccepted() {
        let url = URL(fileURLWithPath: "/Steam/steamapps/appmanifest_3314790.acf")
        let result = SteamLogRedactor.redactURL(url)
        #expect(!result.applied)
    }

    @Test func testCloverpitUrlAccepted() {
        let url = URL(fileURLWithPath: "/Steam/steamapps/common/CloverPit/CloverPit.exe")
        let result = SteamLogRedactor.redactURL(url)
        #expect(!result.applied)
    }
}

// MARK: - Redaction counter

struct SteamRedactionCounterTests {

    @Test func testRecordIncrementsCount() async {
        let counter = SteamRedactionCounter()
        let result = SteamLogRedactor.redact("steamguard code")
        await counter.record(result)
        let snapshot = await counter.snapshot()
        #expect(snapshot.total == 1)
    }

    @Test func testCleanDoesNotIncrement() async {
        let counter = SteamRedactionCounter()
        await counter.record(.clean)
        let snapshot = await counter.snapshot()
        #expect(snapshot.total == 0)
    }

    @Test func testResetClearsCount() async {
        let counter = SteamRedactionCounter()
        let result = SteamLogRedactor.redact("steamguard")
        await counter.record(result)
        await counter.reset()
        let snapshot = await counter.snapshot()
        #expect(snapshot.total == 0)
    }
}
