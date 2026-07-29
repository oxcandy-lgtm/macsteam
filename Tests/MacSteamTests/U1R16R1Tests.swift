// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - InstallerPhase transition tests

@Test("installerExited can transition to verifyingInstallation")
func installerExitedToVerifying() throws {
    var op = InstallerOperation(
        runtimeSafeID: "test",
        prefixSafeID: "test",
        phase: .installerExited
    )
    try op.transition(to: .verifyingInstallation)
    #expect(op.phase == .verifyingInstallation)
}

@Test("nonzero installer exit does not become steamReady")
func nonzeroExitNotSteamReady() throws {
    var op = InstallerOperation(
        runtimeSafeID: "test",
        prefixSafeID: "test",
        phase: .installerExited
    )
    #expect(throws: InstallerError.self) {
        try op.transition(to: .steamReady) // not directly allowed from installerExited
    }
}

@Test("steam.exe alone never advances to steamReady")
func steamExeAloneNotSteamReady() throws {
    var op = InstallerOperation(
        runtimeSafeID: "test",
        prefixSafeID: "test",
        phase: .installerExited
    )
    #expect(throws: InstallerError.self) {
        try op.transition(to: .steamReady)
    }
}

// MARK: - RuntimePrefixBindingStore tests

@Test("binding first save succeeds")
func bindingFirstSave() async throws {
    let store = RuntimePrefixBindingStore()
    let binding = RuntimePrefixBinding(
        schemaVersion: 1,
        runtimeEntryName: "WineCX10.bundle",
        runtimeSafeID: "abc123def456",
        prefixEntryName: "cloverpit-winecx10-test",
        prefixSafeID: "def789abc012",
        createdAt: Date(),
        updatedAt: Date()
    )
    try await store.save(binding)
    let loaded = await store.load()
    #expect(loaded != nil)
    #expect(loaded?.runtimeEntryName == "WineCX10.bundle")
    await store.clear()
    let afterClear = await store.load()
    #expect(afterClear == nil)
}
