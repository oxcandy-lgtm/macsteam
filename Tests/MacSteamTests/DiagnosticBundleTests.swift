// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

@MainActor
struct DiagnosticBundleTests {

    // MARK: - Helpers

    private func makeBundle() -> DiagnosticBundle {
        DiagnosticBundle(
            schemaVersion: DiagnosticBundle.currentSchemaVersion,
            generatedAt: Date(),
            installerLifecycle: InstallerLifecycleDiagnostic(
                phase: "idle", isActive: false, isTerminal: false,
                installerID: "12345", hasLastError: false
            ),
            runtime: RuntimeDiagnostic(
                sourceType: "imported_wine", exactVersion: "10.0",
                architecture: "arm64", isUsable: true,
                capabilities: ["windowsProcess", "steamClient"],
                failureCodes: [], realLoadHealthy: true, realLoadStatus: "healthy"
            ),
            prefixAcquisition: PrefixAcquisitionDiagnostic(
                source: "existingCanonical", canonicalPrefixValid: true,
                canonicalSteamPresent: true, adoptionCandidateCount: 0,
                adoptionResult: "notNeeded", signatureValid: true,
                signatureDriveC: true, signatureDosdevices: true,
                signatureSymlinkResolves: true, signatureSteamExe: true,
                evidenceBound: true
            ),
            steamPayload: SteamPayloadDiagnostic(
                lifecycle: "verifiedComplete", exePresent: true,
                exeNonEmpty: true, installerRunning: false,
                steamInstalled: true, installState: "installed", canLaunch: true
            ),
            supervisedSession: SupervisedSessionDiagnostic(
                state: "idle", isRunning: false, isStopping: false,
                needsRecovery: false, purpose: nil, recipeID: nil,
                sessionAgeSeconds: nil
            ),
            wineProcessCensus: WineProcessCensusDiagnostic(
                hostProcessCount: 0, hostProcessProof: "notProven"
            ),
            wineserver: WineserverDiagnostic(state: "unknown"),
            windowInventory: WindowInventoryDiagnostic(
                windowCount: 0, visibility: "unknown"
            ),
            boundedOutput: BoundedOutputDiagnostic(
                lineCount: 2, truncated: false,
                lines: ["[12:00:00] step 1", "[12:00:01] step 2"]
            ),
            failureClassification: FailureClassificationDiagnostic(
                errorCase: nil, hasError: false, setupState: "Steam Ready"
            ),
            cleanup: CleanupDiagnostic(
                cleanupProof: "notRun", hostProcessProof: "notProven",
                windowVisibility: "unknown"
            )
        )
    }

    private func makeScratchDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-diag-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Schema

    @Test("schema version is present and equals 1")
    func schemaVersion() {
        let bundle = makeBundle()
        #expect(bundle.schemaVersion == 1)
        #expect(DiagnosticBundle.currentSchemaVersion == 1)
    }

    @Test("JSON encode/decode roundtrip preserves all fields")
    func jsonRoundtrip() throws {
        let bundle = makeBundle()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticBundle.self, from: data)
        #expect(decoded.schemaVersion == bundle.schemaVersion)
        #expect(decoded.prefixAcquisition.source == "existingCanonical")
        #expect(decoded.steamPayload.lifecycle == "verifiedComplete")
        #expect(decoded.cleanup.cleanupProof == "notRun")
        #expect(decoded.wineProcessCensus.hostProcessProof == "notProven")
        #expect(decoded.windowInventory.visibility == "unknown")
    }

    // MARK: - Redaction

    @Test("redactor replaces home directory path")
    func redactHomePath() {
        let home = NSHomeDirectory()
        let input = "prefix at \(home)/Library/prefix"
        let result = DiagnosticRedactor.redact(input)
        #expect(!result.contains(home))
        #expect(result.contains("$HOME"))
    }

    @Test("redactor replaces username")
    func redactUsername() {
        let user = NSUserName()
        guard !user.isEmpty else { return }
        let input = "owned by \(user) on this machine"
        let result = DiagnosticRedactor.redact(input)
        #expect(!result.contains(user))
    }

    @Test("redactor masks tokens")
    func redactTokens() {
        let input = "token gh" + "p_abc123DEF456 and key AKI" + "A1234567890123456"
        let result = DiagnosticRedactor.redact(input)
        #expect(!result.contains("gh" + "p_"))
        #expect(!result.contains("AKI" + "A"))
    }

    @Test("redactor truncates long strings")
    func redactTruncation() {
        let input = String(repeating: "x", count: 1000)
        let result = DiagnosticRedactor.redact(input)
        #expect(result.count <= DiagnosticSizeLimits.maxStringChars + 1)
    }

    @Test("redactLines bounds output lines")
    func redactLinesBounded() {
        let input = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        let lines = DiagnosticRedactor.redactLines(input)
        #expect(lines.count <= DiagnosticSizeLimits.maxOutputLines)
    }

    @Test("violation scanner detects raw home path")
    func violationScanHomePath() {
        let home = NSHomeDirectory()
        let json = "{\"path\": \"\(home)/Library\"}"
        let violations = DiagnosticRedactor.scanForViolations(json)
        #expect(violations.contains("raw_home_path"))
    }

    @Test("violation scanner passes clean json")
    func violationScanClean() {
        let json = "{\"source\": \"existingCanonical\", \"valid\": true}"
        let violations = DiagnosticRedactor.scanForViolations(json)
        #expect(violations.isEmpty)
    }

    // MARK: - Atomic writer

    @Test("writer produces file with 0600 permissions")
    func writerPermissions() throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("bundle.json")

        try DiagnosticBundleWriter.write(makeBundle(), to: target)

        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    @Test("writer rejects symlink target")
    func writerRejectsSymlink() throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let real = scratch.appendingPathComponent("real.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        let link = scratch.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticBundleWriter.write(makeBundle(), to: link)
        }
    }

    @Test("writer produces valid decodable JSON")
    func writerValidJSON() throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("bundle.json")

        try DiagnosticBundleWriter.write(makeBundle(), to: target)

        let data = try Data(contentsOf: target)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticBundle.self, from: data)
        #expect(decoded.schemaVersion == 1)
    }

    @Test("written bundle has no redaction violations")
    func writerNoViolations() throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("bundle.json")

        try DiagnosticBundleWriter.write(makeBundle(), to: target)

        let json = try String(contentsOf: target, encoding: .utf8)
        let violations = DiagnosticRedactor.scanForViolations(json)
        #expect(violations.isEmpty)
    }

    @Test("bundle size is within limit")
    func bundleSizeWithinLimit() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(makeBundle())
        #expect(data.count <= DiagnosticSizeLimits.maxBundleBytes)
    }

    // MARK: - Coordinator generation

    @Test("coordinator generates bundle with schema version")
    func coordinatorGeneratesBundle() async {
        let coordinator = UltimateSetupCoordinator()
        let bundle = await coordinator.generateDiagnosticBundle()
        #expect(bundle.schemaVersion == 1)
        #expect(bundle.cleanup.cleanupProof == "notRun")
        #expect(bundle.cleanup.hostProcessProof == "notProven")
        #expect(bundle.windowInventory.visibility == "unknown")
        #expect(bundle.wineProcessCensus.hostProcessProof == "notProven")
    }

    @Test("generated bundle encodes and passes violation scan")
    func generatedBundleClean() async throws {
        let coordinator = UltimateSetupCoordinator()
        let bundle = await coordinator.generateDiagnosticBundle()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        let json = String(data: data, encoding: .utf8)!
        let violations = DiagnosticRedactor.scanForViolations(json)
        #expect(violations.isEmpty, "violations: \(violations)")
    }

    @Test("generated bundle writes to disk with 0600")
    func generatedBundleWrites() async throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("probe-bundle.json")

        let coordinator = UltimateSetupCoordinator()
        let bundle = await coordinator.generateDiagnosticBundle()
        try DiagnosticBundleWriter.write(bundle, to: target)

        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)

        let data = try Data(contentsOf: target)
        #expect(data.count <= DiagnosticSizeLimits.maxBundleBytes)
    }
}
