// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct LauncherStateTests {

    @Test func stateEquality() {
        #expect(LauncherState.inspecting == .inspecting)
        #expect(LauncherState.runtimeMissing == .runtimeMissing)
        #expect(LauncherState.ready == .ready)
        #expect(LauncherState.launching == .launching)
    }

    @Test func runtimeFailureEquality() {
        #expect(RuntimeFailure.bundleNotValid == .bundleNotValid)
        #expect(RuntimeFailure.executableMissing == .executableMissing)
    }

    @Test func errorCodeValues() {
        #expect(ErrorCode.runtimeNotFound.rawValue == "RUNTIME_NOT_FOUND")
        #expect(ErrorCode.nativeMacSteamOnly.rawValue == "NATIVE_MAC_STEAM_ONLY")
        #expect(ErrorCode.gameManifestNotFound.rawValue == "GAME_MANIFEST_NOT_FOUND")
    }
}
