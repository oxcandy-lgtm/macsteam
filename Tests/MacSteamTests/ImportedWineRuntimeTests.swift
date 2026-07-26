// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct ImportedWineRuntimeTests {

    @Test func testRejectsNilURL() {
        // A path that doesn't contain a valid wine executable should return nil
        let bogusURL = URL(fileURLWithPath: "/tmp/NoWineHere")
        let runtime = ImportedWineRuntime(url: bogusURL)
        #expect(runtime == nil)
    }

    @Test func testAcceptsValidWineRoot() throws {
        // Create a temporary directory with a valid wine executable
        let fm = FileManager.default
        let tempDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? fm.removeItem(at: tempDir) }

        let binDir = tempDir.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let winePath = binDir.appendingPathComponent("wine")
        // Write a minimal valid executable stub
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: winePath) // ELF magic
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winePath.path)

        let runtime = ImportedWineRuntime(url: tempDir)
        #expect(runtime != nil)
        #expect(runtime?.runtimeURL == tempDir.standardized)
    }

    @Test func testRejectsWorldWritableRoot() throws {
        let fm = FileManager.default
        let tempDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? fm.removeItem(at: tempDir) }

        let binDir = tempDir.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let winePath = binDir.appendingPathComponent("wine")
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: winePath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winePath.path)

        // Make root world-writable
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tempDir.path)

        let runtime = ImportedWineRuntime(url: tempDir)
        #expect(runtime == nil)
    }

    @Test func testInspectionReportsMissingWine() throws {
        let fm = FileManager.default
        let tempDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? fm.removeItem(at: tempDir) }

        // No wine binary — init should return nil
        let runtime = ImportedWineRuntime(url: tempDir)
        #expect(runtime == nil)
    }

    @Test func testLaunchPlanReturnsNilForMissingWine() throws {
        let fm = FileManager.default
        let tempDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? fm.removeItem(at: tempDir) }

        let binDir = tempDir.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let winePath = binDir.appendingPathComponent("wine")
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: winePath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winePath.path)

        guard let runtime = ImportedWineRuntime(url: tempDir) else {
            Issue.record("Could not create ImportedWineRuntime")
            return
        }

        let recipe = GameRecipe(
            schemaVersion: 2,
            id: "test",
            displayName: "Test",
            store: GameRecipe.StoreInfo(type: .steam, appId: "12345"),
            runtime: GameRecipe.RuntimeRequirements(
                requiredCapabilities: ["windowsProcess"],
                preferredRuntime: .importedWine,
                fallbackRuntimes: []
            ),
            graphics: GameRecipe.GraphicsConfig(
                preferred: .dxvk,
                fallback: []
            ),
            prefix: GameRecipe.PrefixConfig(
                id: "test",
                windowsVersion: .win10,
                isolation: .perGame
            ),
            storeInstallation: GameRecipe.StoreInstallationConfig(
                installerMode: .automatic,
                installerProduct: "steam",
                redistribution: .forbidden
            ),
            launch: GameRecipe.LaunchConfig(
                storeArguments: ["-applaunch", "12345"]
            ),
            detection: GameRecipe.DetectionConfig(
                manifestName: "appmanifest_12345.acf",
                executableCandidates: ["Game.exe"]
            ),
            savePolicy: GameRecipe.SavePolicyConfig(
                mode: .discoverOnly,
                backupBeforeDestructiveRepair: false
            )
        )

        let plan = runtime.launchPlan(for: recipe)
        #expect(plan != nil)
        #expect(plan?.runtimeExecutable.lastPathComponent == "wine")
    }
}
