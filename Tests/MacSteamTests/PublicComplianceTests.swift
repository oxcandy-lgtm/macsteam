// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct PublicComplianceTests {

    private let sourcesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/MacSteamTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // project root
        .appendingPathComponent("Sources/MacSteam")

    private let testsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests")

    @Test func testNoBundledSteam() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate Sources directory")
            return
        }

        var found = false
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            // Look for a bundled "steam.exe" — i.e. a file reference suggesting
            // the actual binary is embedded in the bundle, not just a path string
            // for locating an already-installed Steam.
            let bundledPatterns = ["Resources/steam.exe", "Bundle/steam.exe", "bundled/steam.exe"]
            for pattern in bundledPatterns {
                if content.contains(pattern) {
                    found = true
                    break
                }
            }
        }
        #expect(!found, "Bundled steam.exe must not appear in Sources")
    }

    @Test func testNoBundledCloverPit() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate Sources directory")
            return
        }

        var found = false
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if content.contains("CloverPit.exe") {
                found = true
                break
            }
        }
        #expect(!found, "CloverPit.exe must not appear in Sources")
    }

    @Test func testNoCredentialsInSource() throws {
        let fm = FileManager.default
        // Patterns that should never appear as full raw strings in source.
        // NOTE: PathRedactor.swift is exempt — it uses regex redaction patterns,
        // not actual secrets. Construct patterns dynamically to avoid
        // false-positive secret scans.
        let ghp = "gh" + "p_"
        let akia = "AK" + "IA"
        let xoxb = "xo" + "xb-"
        let patterns = [ghp, akia, xoxb]
        let exemptFiles = ["PathRedactor.swift"]

        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate Sources directory")
            return
        }

        var violations: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard !exemptFiles.contains(fileURL.lastPathComponent) else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for pattern in patterns {
                if content.contains(pattern) {
                    violations.append("\(fileURL.lastPathComponent): found pattern '\(pattern)'")
                }
            }
        }
        if !violations.isEmpty {
            Issue.record("Credential patterns found: \(violations.joined(separator: "; "))")
        }
    }

    @Test func testNoPersonalPaths() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate Sources directory")
            return
        }

        var violations: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if content.contains("/Users/hmmrios") || content.contains("hmmrios") {
                violations.append(fileURL.lastPathComponent)
            }
        }
        #expect(violations.isEmpty, "Personal paths found in: \(violations.joined(separator: ", "))")
    }

    @Test func testSPDXHeaders() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate Sources directory")
            return
        }

        var missingSPDX: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let firstLines = content.prefix(200)
            if !firstLines.contains("SPDX-License-Identifier:") {
                missingSPDX.append(fileURL.lastPathComponent)
            }
        }
        #expect(missingSPDX.isEmpty, "Files missing SPDX header: \(missingSPDX.joined(separator: ", "))")
    }
}
