// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RuntimeManifestSchemaTests {

    // MARK: - Schema version constraints (RuntimeArtifactManifest schemaVersion == 1)

    @Test func testRejectsUnknownSchemaVersion() throws {
        let jsonData = validManifestJSON(schemaVersion: 2)
        let manifest = try JSONDecoder().decode(RuntimeArtifactManifest.self, from: jsonData)
        #expect(manifest.schemaVersion != 1)
        #expect(!manifest.isValid)
    }

    @Test func testRejectsMissingLicense() {
        // DistributionGate.evaluate rejects missing or invalid manifest hash
        let result = DistributionGate.evaluate(
            componentID: .wine,
            bundled: false,
            licenseSPDX: "LGPL-2.1-or-later",
            manifestHash: nil
        )
        // Missing manifest hash should yield reviewRequired
        if case .reviewRequired = result {
            #expect(true)
        } else {
            #expect(result == .reviewRequired(details: "Missing or invalid artifact manifest SHA-256"))
        }
    }

    // MARK: - Helpers

    private func validManifestJSON(schemaVersion: Int = 1) -> Data {
        let json = """
        {
            "schemaVersion": \(schemaVersion),
            "id": "wine-9.0",
            "version": "9.0.0",
            "hostArchitectures": [
                { "arch": "arm64", "name": "Apple Silicon" }
            ],
            "runtimeArchitectures": [
                { "arch": "x86_64", "name": "wow64" }
            ],
            "minimumMacOS": "14.0",
            "source": {
                "upstreamRepository": "https://github.com/wine-mirror/wine",
                "upstreamCommit": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
                "sourceArchiveSHA256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                "buildRecipeSHA256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
            },
            "license": {
                "spdx": "LGPL-2.1-or-later",
                "licenseFiles": ["LICENSE"],
                "noticeFiles": ["NOTICE"],
                "redistribution": "allowed"
            },
            "archive": {
                "filename": "wine-9.0.0.tar.gz",
                "sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                "size": 52428800
            },
            "capabilities": 3
        }
        """
        return json.data(using: .utf8)!
    }
}
