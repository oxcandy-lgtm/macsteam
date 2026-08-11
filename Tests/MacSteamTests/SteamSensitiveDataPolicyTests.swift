// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SteamSensitiveDataPolicyTests {

    // MARK: - Sensitive paths

    @Test func testLoginusersVdfDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/config/loginusers.vdf")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testSsfnDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/ssfn123456789")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testConfigVdfDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/config/config.vdf")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testCookiesDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Cookies")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testLocalStorageDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Local Storage/leveldb")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testSessionStorageDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/Session Storage/")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testIndexedDbDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/IndexedDB/chrome-extension")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testHtmlcacheDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/htmlcache/cache")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testCrashDumpDenied() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/minidump.dmp")
        #expect(SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testAppmanifestAccepted() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/steamapps/appmanifest_3314790.acf")
        #expect(!SteamSensitiveDataPolicy.isSensitive(url))
    }

    @Test func testCloverpitExeAccepted() {
        let url = URL(fileURLWithPath: "/Users/test/Library/Application Support/Steam/steamapps/common/CloverPit/CloverPit.exe")
        #expect(!SteamSensitiveDataPolicy.isSensitive(url))
    }

    // MARK: - Sensitive arguments

    @Test func testLoginArgumentRejected() {
        #expect(SteamSensitiveDataPolicy.isSensitiveArgument("+login test-only-account"))
    }

    @Test func testGuardCodeArgumentRejected() {
        #expect(SteamSensitiveDataPolicy.isSensitiveArgument("+set_steam_guard_code ABCDE"))
    }

    @Test func testOAuthArgumentRejected() {
        #expect(SteamSensitiveDataPolicy.isSensitiveArgument("oauth_token=abc123"))
    }

    @Test func testNormalArgumentAccepted() {
        #expect(!SteamSensitiveDataPolicy.isSensitiveArgument("--force-d3d11"))
    }

    @Test func testAppLaunchArgumentAccepted() {
        #expect(!SteamSensitiveDataPolicy.isSensitiveArgument("-applaunch 3314790"))
    }

    // MARK: - Environment keys

    @Test func testSteamPasswordEnvDenied() {
        #expect(SteamSensitiveDataPolicy.isSensitiveEnvironmentKey("STEAM_PASSWORD"))
    }

    @Test func testSteamTokenEnvDenied() {
        #expect(SteamSensitiveDataPolicy.isSensitiveEnvironmentKey("STEAM_TOKEN"))
    }

    @Test func testHomeEnvAccepted() {
        #expect(!SteamSensitiveDataPolicy.isSensitiveEnvironmentKey("HOME"))
    }

    @Test func testPathEnvAccepted() {
        #expect(!SteamSensitiveDataPolicy.isSensitiveEnvironmentKey("PATH"))
    }
}
