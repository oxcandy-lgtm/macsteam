// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct AppBrandTests {

    @Test func displayNameIsCorrect() {
        #expect(AppBrand.displayName == "MacsTeam")
    }

    @Test func bundleIdentifierIsReverseDNS() {
        #expect(AppBrand.bundleIdentifier == "app.macsteam.launcher")
    }

    @Test func noInternalBrandingLeak() {
        let forbiddenInTypes = ["MacSteamRuntime", "MacSteamRecipe", "MacSteamManager"]
        for name in forbiddenInTypes {
            #expect(name.contains("MacSteam"))
        }
    }
}
