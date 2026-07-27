// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SteamPathDenylistTests {

    // MARK: - Denied paths

    @Test func testLoginusersVdfDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/config/loginusers.vdf")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testSsfnDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/ssfn123456789")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testConfigVdfDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/config/config.vdf")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testCookiesDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Cookies")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testCrashDumpDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/crash.dmp")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testLocalStorageDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Local Storage/test")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testSessionStorageDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Session Storage/data")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testHtmlcacheDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/htmlcache/cache")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    @Test func testUserdataDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/userdata/123456")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    // MARK: - Allowed paths

    @Test func testAppmanifestAllowed() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/steamapps/appmanifest_3314790.acf")
        let auth = SteamPathDenylist.authorizeRead(url)
        if case .allowManifest = auth {
            Bool(true)
        } else {
            Issue.record("Expected allowManifest, got \(auth)")
        }
    }

    @Test func testCloverpitExeAllowed() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/steamapps/common/CloverPit/CloverPit.exe")
        let auth = SteamPathDenylist.authorizeRead(url)
        if case .allowExecutableMetadata = auth {
            Bool(true)
        } else {
            Issue.record("Expected allowExecutableMetadata, got \(auth)")
        }
    }

    // MARK: - Unknown paths (fail-closed)

    @Test func testUnknownPathDenied() {
        let url = URL(fileURLWithPath: "/some/random/path")
        #expect(SteamPathDenylist.authorizeRead(url) == .deny)
    }

    // MARK: - Manifest keys

    @Test func testManifestKeyAppidAllowed() {
        #expect(SteamPathDenylist.isAllowedManifestKey("appid"))
    }

    @Test func testManifestKeyInstalldirAllowed() {
        #expect(SteamPathDenylist.isAllowedManifestKey("installdir"))
    }

    @Test func testManifestKeyStateFlagsAllowed() {
        #expect(SteamPathDenylist.isAllowedManifestKey("StateFlags"))
    }

    @Test func testManifestKeyLoginRejected() {
        #expect(!SteamPathDenylist.isAllowedManifestKey("login"))
    }

    @Test func testManifestKeyPasswordRejected() {
        #expect(!SteamPathDenylist.isAllowedManifestKey("password"))
    }

    @Test func testManifestKeyRejectedByDefault() {
        #expect(!SteamPathDenylist.isAllowedManifestKey("unknown_key"))
    }
}
