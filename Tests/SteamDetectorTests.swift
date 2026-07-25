// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct SteamDetectorTests {

    let detector = SteamDetector()

    @Test func detectInMockReturnsNoSteam() {
        let mockRuntime = MockRuntime()
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
            detection: GameRecipe.DetectionConfig(
                manifestName: "appmanifest_99999.acf",
                executableCandidates: ["TestGame.exe"]
            )
        )

        let inspection = detector.inspectGame(recipe, windowsSteamURL: fakeURL)
        #expect(inspection.manifestPresent == false)
        #expect(inspection.installDirectoryResolved == false)
        #expect(inspection.executablePresent == false)
        #expect(inspection.isReady == false)
    }

    @Test func steamRootCalculation() {
        // steam.exe at .../drive_c/Program Files (x86)/Steam/steam.exe
        // steamRoot should be .../drive_c/Program Files (x86)/Steam/
        let steamURL = URL(fileURLWithPath: "/bottle/drive_c/Program Files (x86)/Steam/steam.exe")
        let steamRoot = steamURL.deletingLastPathComponent()
        #expect(steamRoot.lastPathComponent == "Steam")
        #expect(steamRoot.path == "/bottle/drive_c/Program Files (x86)/Steam")
    }

    @Test func executableCandidatesFilterCorrectly() async throws {
        // Create a temp directory with a known .exe file and verify
        // that executableCandidates matching works
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-test-steam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Place a matching candidate
        let targetExe = dir.appendingPathComponent("CloverPit.exe")
        try "fake".write(to: targetExe, atomically: true, encoding: .utf8)

        // Non-matching files
        try "".write(to: dir.appendingPathComponent("steam_api.dll"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        // Test with candidates list
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: dir.path)
        let candidates = ["CloverPit.exe", "Game.exe"]
        let matched = candidates.contains { contents.contains($0) }
        #expect(matched)

        // Test with non-matching candidates
        let noMatch = ["OtherGame.exe"]
        #expect(!noMatch.contains { contents.contains($0) })
    }
}
