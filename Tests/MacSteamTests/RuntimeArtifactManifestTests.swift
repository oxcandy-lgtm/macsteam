// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RuntimeArtifactManifestTests {

    private func validManifestJSON() -> Data {
        let json = """
        {
            "schemaVersion": 1,
            "id": "wine-9.0",
            "version": "9.0.0",
            "hostArchitectures": [
                { "arch": "arm64", "name": "Apple Silicon" },
                { "arch": "x86_64", "name": "Intel" }
            ],
            "runtimeArchitectures": [
                { "arch": "x86_64", "name": "wow64", "wow64": true }
            ],
            "minimumMacOS": "14.0",
            "source": {
                "upstreamRepository": "https://github.com/wine-mirror/wine",
                "upstreamCommit": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
                "sourceArchiveSHA256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
                "patchsetSHA256": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
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

    @Test func testValidManifestPassesValidation() throws {
        let jsonData = validManifestJSON()
        let manifest = try JSONDecoder().decode(RuntimeArtifactManifest.self, from: jsonData)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.isValid)
        #expect(manifest.license.spdx == "LGPL-2.1-or-later")
        #expect(manifest.source.sourceArchiveSHA256.count == 64)
    }

    @Test func testRejectsMissingSHA256() throws {
        let jsonData = validManifestJSON()
        var manifest = try JSONDecoder().decode(RuntimeArtifactManifest.self, from: jsonData)
        // Modify the sha256 to be shorter than 64 characters
        manifest = RuntimeArtifactManifest(
            schemaVersion: manifest.schemaVersion,
            id: manifest.id,
            version: manifest.version,
            hostArchitectures: manifest.hostArchitectures,
            runtimeArchitectures: manifest.runtimeArchitectures,
            minimumMacOS: manifest.minimumMacOS,
            source: SourceIdentity(
                upstreamRepository: manifest.source.upstreamRepository,
                upstreamCommit: manifest.source.upstreamCommit,
                sourceArchiveSHA256: "tooshort",
                buildRecipeSHA256: manifest.source.buildRecipeSHA256
            ),
            license: manifest.license,
            archive: manifest.archive,
            capabilities: manifest.capabilities
        )
        #expect(!manifest.isValid)
    }

    @Test func testRejectsEmptySPDX() throws {
        let jsonData = validManifestJSON()
        var manifest = try JSONDecoder().decode(RuntimeArtifactManifest.self, from: jsonData)
        manifest = RuntimeArtifactManifest(
            schemaVersion: manifest.schemaVersion,
            id: manifest.id,
            version: manifest.version,
            hostArchitectures: manifest.hostArchitectures,
            runtimeArchitectures: manifest.runtimeArchitectures,
            minimumMacOS: manifest.minimumMacOS,
            source: manifest.source,
            license: LicenseIdentity(
                spdx: "",
                licenseFiles: manifest.license.licenseFiles,
                noticeFiles: manifest.license.noticeFiles,
                redistribution: manifest.license.redistribution
            ),
            archive: manifest.archive,
            capabilities: manifest.capabilities
        )
        #expect(!manifest.isValid)
    }
}
