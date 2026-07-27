// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SteamPathDenylistTests {

    // MARK: - Denied paths

    @Test func testLoginusersVdfDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/config/loginusers.vdf")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testSsfnDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/ssfn123456789")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testConfigVdfDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/config/config.vdf")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testCookiesDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Cookies")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testCrashDumpDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/crash.dmp")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testLocalStorageDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Local Storage/test")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testSessionStorageDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Session Storage/data")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testHtmlcacheDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/htmlcache/cache")
        #expect(SteamPathDenylist.isDenied(url))
    }

    @Test func testUserdataDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/userdata/123456")
        #expect(SteamPathDenylist.isDenied(url))
    }

    // MARK: - Allowed paths

    @Test func testAppmanifestAllowed() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/steamapps/appmanifest_3314790.acf")
        #expect(SteamPathDenylist.isAllowed(url))
    }

    @Test func testCloverpitExeAllowed() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/steamapps/common/CloverPit/CloverPit.exe")
        #expect(SteamPathDenylist.isAllowed(url))
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
