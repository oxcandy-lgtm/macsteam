// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct DistributionGateTests {

    @Test func testSteamBundledRejected() {
        let result = DistributionGate.evaluate(
            componentID: .steamClient,
            bundled: true,
            licenseSPDX: "Proprietary",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .forbidden(reason: "steam-client is proprietary and must not be bundled"))
    }

    @Test func testD3DMetalBundledRejected() {
        let result = DistributionGate.evaluate(
            componentID: .d3dmetal,
            bundled: true,
            licenseSPDX: "Proprietary",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .forbidden(reason: "d3dmetal is proprietary and must not be bundled"))
    }

    @Test func testSteamUnbundledAlsoForbidden() {
        // Steam Client redistribution is never permitted, even when not bundled.
        let result = DistributionGate.evaluate(
            componentID: .steamClient,
            bundled: false,
            licenseSPDX: "Proprietary",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .forbidden(reason: "Steam Client redistribution is never permitted"))
    }

    @Test func testD3DMetalUnbundledForbidden() {
        let result = DistributionGate.evaluate(
            componentID: .d3dmetal,
            bundled: false,
            licenseSPDX: "Proprietary",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .forbidden(reason: "D3DMetal redistribution is forbidden until reviewed"))
    }

    @Test func testWineAllowedWithManifest() {
        let result = DistributionGate.evaluate(
            componentID: .wine,
            bundled: false,
            licenseSPDX: "LGPL-2.1-or-later",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .allowed)
    }

    @Test func testUnknownLicenseRequiresReview() {
        let result = DistributionGate.evaluate(
            componentID: .wine,
            bundled: false,
            licenseSPDX: "MIT",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .reviewRequired(details: "Unexpected Wine license: MIT"))
    }

    @Test func testMissingManifestHashRequiresReview() {
        let result = DistributionGate.evaluate(
            componentID: .wine,
            bundled: false,
            licenseSPDX: "LGPL-2.1-or-later",
            manifestHash: nil
        )
        #expect(result == .reviewRequired(details: "Missing or invalid artifact manifest SHA-256"))
    }

    @Test func testInvalidManifestHashLengthRequiresReview() {
        let result = DistributionGate.evaluate(
            componentID: .wine,
            bundled: false,
            licenseSPDX: "LGPL-2.1-or-later",
            manifestHash: "too-short"
        )
        #expect(result == .reviewRequired(details: "Missing or invalid artifact manifest SHA-256"))
    }

    @Test func testDXVKAllowedWithManifest() {
        let result = DistributionGate.evaluate(
            componentID: .dxvkMacOS,
            bundled: false,
            licenseSPDX: "Zlib",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .allowed)
    }

    @Test func testMoltenVKAllowedWithManifest() {
        let result = DistributionGate.evaluate(
            componentID: .moltenvk,
            bundled: false,
            licenseSPDX: "Apache-2.0",
            manifestHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        )
        #expect(result == .allowed)
    }
}
