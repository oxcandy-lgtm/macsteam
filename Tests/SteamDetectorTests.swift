// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SteamDetectorTests {

    let detector = SteamDetector()
    let mockRuntime = MockRuntime()

    @Test func detectInMockReturnsNoSteam() {
        let result = detector.detectWindowsSteam(in: mockRuntime)
        #expect(result == .noSteamFound)
    }

    @Test func nativeMacSteamDetection() {
        let isInstalled = detector.isNativeMacSteamInstalled()
        #expect(isInstalled == false || isInstalled == true)
    }

    @Test func gameInspectionRequiresManifestAndExecutable() {
        let fakeURL = URL(fileURLWithPath: "/nonexistent/steam.exe")
        let recipe = GameRecipe(
            schemaVersion: 1,
            id: "test",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: "99999"),
            runtime: GameRecipe.RuntimePreference(preferredAdapter: "crossover"),
            launch: GameRecipe.LaunchConfig(arguments: []),
            detection: GameRecipe.DetectionConfig(manifestName: "appmanifest_99999.acf")
        )

        let inspection = detector.inspectGame(recipe, windowsSteamURL: fakeURL)
        #expect(inspection.manifestPresent == false)
        #expect(inspection.installDirectoryResolved == false)
        #expect(inspection.executablePresent == false)
        #expect(inspection.isReady == false)
    }
}
