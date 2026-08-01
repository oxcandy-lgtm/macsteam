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
        let result = DiagnosticRedactor.sanitize(input)
        #expect(!result.contains(home))
        #expect(result.contains("$HOME"))
    }

    @Test("redactor replaces username")
    func redactUsername() {
        let user = NSUserName()
        guard !user.isEmpty else { return }
        let input = "owned by \(user) on this machine"
        let result = DiagnosticRedactor.sanitize(input)
        #expect(!result.contains(user))
    }

    @Test("redactor masks tokens")
    func redactTokens() {
        let input = "token gh" + "p_abc123DEF456 and key AKI" + "A1234567890123456"
        let result = DiagnosticRedactor.sanitize(input)
        #expect(!result.contains("gh" + "p_"))
        #expect(!result.contains("AKI" + "A"))
    }

    @Test("redactor truncates long strings")
    func redactTruncation() {
        let input = String(repeating: "x", count: 1000)
        let result = DiagnosticRedactor.sanitize(input)
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

    // MARK: - Trusted root containment

    @Test("validatedTarget rejects path traversal")
    func trustedRootRejectsTraversal() {
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validatedTarget(filename: "../escape.json")
        }
    }

    @Test("validatedTarget rejects absolute path")
    func trustedRootRejectsAbsolute() {
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validatedTarget(filename: "/tmp/evil.json")
        }
    }

    @Test("validatedTarget rejects nested path")
    func trustedRootRejectsNested() {
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validatedTarget(filename: "sub/dir/bundle.json")
        }
    }

    @Test("validatedTarget accepts simple filename")
    func trustedRootAcceptsSimple() throws {
        let target = try DiagnosticTrustedRoot.validatedTarget(filename: "bundle.json")
        #expect(target.path.hasPrefix(DiagnosticTrustedRoot.root.path))
        #expect(target.lastPathComponent == "bundle.json")
    }

    // MARK: - Symlink chain rejection

    @Test("writer rejects intermediate symlink in path chain")
    func writerRejectsIntermediateSymlink() throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let realDir = scratch.appendingPathComponent("real-dir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let linkDir = scratch.appendingPathComponent("link-dir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        let target = linkDir.appendingPathComponent("bundle.json")

        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticBundleWriter.write(makeBundle(), to: target)
        }
    }

    // MARK: - Tmp cleanup

    @Test("no tmp files remain after failed write")
    func tmpCleanupOnFailure() throws {
        let scratch = makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let link = scratch.appendingPathComponent("link.json")
        let real = scratch.appendingPathComponent("real.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try? DiagnosticBundleWriter.write(makeBundle(), to: link)

        let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        let tmpFiles = contents.filter { $0.hasSuffix(".tmp") }
        #expect(tmpFiles.isEmpty, "tmp files remaining: \(tmpFiles)")
    }

    // MARK: - Central sanitizer

    @Test("sanitizer strips password patterns")
    func sanitizerPassword() {
        let input = "login pass" + "word=secret123 done"
        let result = DiagnosticRedactor.sanitize(input)
        #expect(!result.contains("secret123"))
    }

    @Test("sanitizer strips cookie patterns")
    func sanitizerCookie() {
        let input = "set cookie" + "=abc123; path=/"
        let result = DiagnosticRedactor.sanitize(input)
        #expect(!result.contains("abc123"))
    }

    @Test("sanitizer strips authorization patterns")
    func sanitizerAuthorization() {
        let input = "header Authoriz" + "ation: Bearer tok123"
        let result = DiagnosticRedactor.sanitize(input)
        #expect(!result.contains("tok123"))
    }

    @Test("sanitizer replaces absolute paths")
    func sanitizerAbsolutePath() {
        let result = DiagnosticRedactor.sanitize("/etc/passwd")
        #expect(result == "<path>")
    }

    @Test("sanitizeArray enforces bounds")
    func sanitizeArrayBounds() {
        let items = (0..<100).map { "item-\($0)" }
        let result = DiagnosticRedactor.sanitizeArray(items)
        #expect(result.count == DiagnosticSizeLimits.maxArrayElements)
    }

    // MARK: - Sanitized bundle

    @Test("sanitized bundle passes violation scan")
    func sanitizedBundleClean() throws {
        let bundle = makeBundle().sanitized()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let json = String(data: data, encoding: .utf8)!
        #expect(DiagnosticRedactor.scanForViolations(json).isEmpty)
    }

    // MARK: - Static CI guard

    @Test("no String(describing: Error) in diagnostic source")
    func noErrorDescribingInDiagnostics() throws {
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacSteam/Diagnostics")
        let files = try FileManager.default.contentsOfDirectory(atPath: sourceDir.path)
        for file in files where file.hasSuffix(".swift") {
            let content = try String(contentsOfFile: sourceDir.appendingPathComponent(file).path, encoding: .utf8)
            #expect(!content.contains("String(describing:"), "\(file) must not use String(describing:) for errors")
        }
    }

    // MARK: - Export authority

    @Test("exportDiagnosticBundle writes to trusted root")
    func exportAuthority() async throws {
        let coordinator = UltimateSetupCoordinator()
        let target = try await coordinator.exportDiagnosticBundle(filename: "test-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: target) }

        #expect(target.path.hasPrefix(DiagnosticTrustedRoot.root.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let data = try Data(contentsOf: target)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticBundle.self, from: data)
        #expect(decoded.schemaVersion == 1)
    }

    // MARK: - Credential assignment detection

    @Test("credential scan detects AWS_SECRET_ACCESS_KEY assignment")
    func credScanAwsSecret() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("AWS_SECRET_ACCESS_KEY" + "=wJalrXUtnFEMI")
        #expect(!hits.isEmpty)
    }

    @Test("credential scan detects API_KEY assignment")
    func credScanApiKey() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("MY_API_KEY" + ": abc123")
        #expect(!hits.isEmpty)
    }

    @Test("credential scan detects TOKEN assignment")
    func credScanToken() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("TOKEN" + " secretval")
        #expect(!hits.isEmpty)
    }

    @Test("credential scan detects PASSWORD assignment")
    func credScanPassword() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("PASS" + "WORD=hunter2")
        #expect(!hits.isEmpty)
    }

    @Test("credential scan detects --password flag")
    func credScanPasswordFlag() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("--pass" + "word secret")
        #expect(!hits.isEmpty)
    }

    @Test("credential scan detects --token flag")
    func credScanTokenFlag() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("--to" + "ken=abc")
        #expect(!hits.isEmpty)
    }

    @Test("credential scan passes clean text")
    func credScanClean() {
        let hits = DiagnosticRedactor.scanForCredentialAssignments("source: existingCanonical, valid: true")
        #expect(hits.isEmpty)
    }

    @Test("violation scanner catches credential assignments in JSON")
    func violationScanCredentialAssignment() {
        let json = "{\"line\": \"AWS_SECRET_ACCESS_KEY" + "=wJalrX\"}"
        let violations = DiagnosticRedactor.scanForViolations(json)
        #expect(violations.contains("credential_assignment"))
    }

    // MARK: - Filename validation

    @Test("filename rejects backslash")
    func filenameRejectsBackslash() {
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validateFilename("bundle\\.json")
        }
    }

    @Test("filename rejects control characters")
    func filenameRejectsControlChars() {
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validateFilename("bundle\u{0001}.json")
        }
    }

    @Test("filename rejects empty")
    func filenameRejectsEmpty() {
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validateFilename("")
        }
    }

    @Test("filename rejects overlong")
    func filenameRejectsOverlong() {
        let long = String(repeating: "a", count: 300) + ".json"
        #expect(throws: DiagnosticBundleWriter.WriteError.self) {
            try DiagnosticTrustedRoot.validateFilename(long)
        }
    }

    // MARK: - Full path chain validation

    @Test("validateFullPathChain passes for real home path")
    func fullPathChainValid() throws {
        try DiagnosticTrustedRoot.validateFullPathChain()
    }
}
