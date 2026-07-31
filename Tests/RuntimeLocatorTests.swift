// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RuntimeLocatorTests {

    let locator = RuntimeLocator()

    @Test func validateStoredRuntimeRejectsNonexistent() {
        let badURL = URL(fileURLWithPath: "/Applications/Nonexistent.app")
        #expect(locator.validateStoredRuntime(at: badURL) == false)
    }

    @Test func locateRuntimeAtCustomPathReturnsNilForMissing() {
        let custom = URL(fileURLWithPath: "/tmp/NotCrossOver.app")
        let result = locator.locateRuntime(at: custom)
        #expect(result == nil)
    }

    @Test func locatePreferredReturnsNilWhenNotFound() {
        let result = locator.locatePreferredRuntime()
        #expect(result == nil || result?.id == "crossover")
    }
}
