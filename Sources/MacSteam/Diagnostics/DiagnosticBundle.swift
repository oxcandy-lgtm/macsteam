// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Schema (versioned JSON)

struct DiagnosticBundle: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let installerLifecycle: InstallerLifecycleDiagnostic
    let runtime: RuntimeDiagnostic
    let prefixAcquisition: PrefixAcquisitionDiagnostic
    let steamPayload: SteamPayloadDiagnostic
    let supervisedSession: SupervisedSessionDiagnostic
    let wineProcessCensus: WineProcessCensusDiagnostic
    let wineserver: WineserverDiagnostic
    let windowInventory: WindowInventoryDiagnostic
    let boundedOutput: BoundedOutputDiagnostic
    let failureClassification: FailureClassificationDiagnostic
    let cleanup: CleanupDiagnostic

    static let currentSchemaVersion = 1

    func sanitized() -> DiagnosticBundle {
        DiagnosticBundle(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            installerLifecycle: InstallerLifecycleDiagnostic(
                phase: DiagnosticRedactor.sanitize(installerLifecycle.phase),
                isActive: installerLifecycle.isActive,
                isTerminal: installerLifecycle.isTerminal,
                installerID: DiagnosticRedactor.sanitize(installerLifecycle.installerID),
                hasLastError: installerLifecycle.hasLastError
            ),
            runtime: RuntimeDiagnostic(
                sourceType: runtime.sourceType.map(DiagnosticRedactor.sanitize),
                exactVersion: runtime.exactVersion.map(DiagnosticRedactor.sanitize),
                architecture: runtime.architecture.map(DiagnosticRedactor.sanitize),
                isUsable: runtime.isUsable,
                capabilities: DiagnosticRedactor.sanitizeArray(runtime.capabilities),
                failureCodes: DiagnosticRedactor.sanitizeArray(runtime.failureCodes),
                realLoadHealthy: runtime.realLoadHealthy,
                realLoadStatus: runtime.realLoadStatus.map(DiagnosticRedactor.sanitize)
            ),
            prefixAcquisition: PrefixAcquisitionDiagnostic(
                source: prefixAcquisition.source.map(DiagnosticRedactor.sanitize),
                canonicalPrefixValid: prefixAcquisition.canonicalPrefixValid,
                canonicalSteamPresent: prefixAcquisition.canonicalSteamPresent,
                adoptionCandidateCount: prefixAcquisition.adoptionCandidateCount,
                adoptionResult: prefixAcquisition.adoptionResult.map(DiagnosticRedactor.sanitize),
                signatureValid: prefixAcquisition.signatureValid,
                signatureDriveC: prefixAcquisition.signatureDriveC,
                signatureDosdevices: prefixAcquisition.signatureDosdevices,
                signatureSymlinkResolves: prefixAcquisition.signatureSymlinkResolves,
                signatureSteamExe: prefixAcquisition.signatureSteamExe,
                evidenceBound: prefixAcquisition.evidenceBound
            ),
            steamPayload: SteamPayloadDiagnostic(
                lifecycle: DiagnosticRedactor.sanitize(steamPayload.lifecycle),
                exePresent: steamPayload.exePresent,
                exeNonEmpty: steamPayload.exeNonEmpty,
                installerRunning: steamPayload.installerRunning,
                steamInstalled: steamPayload.steamInstalled,
                installState: steamPayload.installState.map(DiagnosticRedactor.sanitize),
                canLaunch: steamPayload.canLaunch
            ),
            supervisedSession: SupervisedSessionDiagnostic(
                state: DiagnosticRedactor.sanitize(supervisedSession.state),
                isRunning: supervisedSession.isRunning,
                isStopping: supervisedSession.isStopping,
                needsRecovery: supervisedSession.needsRecovery,
                purpose: supervisedSession.purpose.map(DiagnosticRedactor.sanitize),
                recipeID: supervisedSession.recipeID.map(DiagnosticRedactor.sanitize),
                sessionAgeSeconds: supervisedSession.sessionAgeSeconds
            ),
            wineProcessCensus: WineProcessCensusDiagnostic(
                hostProcessCount: wineProcessCensus.hostProcessCount,
                zombieCount: wineProcessCensus.zombieCount,
                orphanCount: wineProcessCensus.orphanCount,
                totalLive: wineProcessCensus.totalLive,
                censusError: wineProcessCensus.censusError.map(DiagnosticRedactor.sanitize),
                hostProcessProof: DiagnosticRedactor.sanitize(wineProcessCensus.hostProcessProof),
                liveDescendants: wineProcessCensus.liveDescendants,
                liveOrphans: wineProcessCensus.liveOrphans,
                exitedCount: wineProcessCensus.exitedCount,
                pidReuseCount: wineProcessCensus.pidReuseCount,
                unresolvedOutcomes: wineProcessCensus.unresolvedOutcomes,
                silentSnapshotDrops: wineProcessCensus.silentSnapshotDrops
            ),
            wineserver: WineserverDiagnostic(
                state: DiagnosticRedactor.sanitize(wineserver.state)
            ),
            windowInventory: WindowInventoryDiagnostic(
                windowCount: windowInventory.windowCount,
                visibility: DiagnosticRedactor.sanitize(windowInventory.visibility)
            ),
            boundedOutput: BoundedOutputDiagnostic(
                lineCount: boundedOutput.lineCount,
                truncated: boundedOutput.truncated,
                lines: DiagnosticRedactor.sanitizeArray(boundedOutput.lines)
            ),
            failureClassification: FailureClassificationDiagnostic(
                errorCase: failureClassification.errorCase.map(DiagnosticRedactor.sanitize),
                hasError: failureClassification.hasError,
                setupState: DiagnosticRedactor.sanitize(failureClassification.setupState)
            ),
            cleanup: CleanupDiagnostic(
                cleanupProof: DiagnosticRedactor.sanitize(cleanup.cleanupProof),
                hostProcessProof: DiagnosticRedactor.sanitize(cleanup.hostProcessProof),
                windowVisibility: DiagnosticRedactor.sanitize(cleanup.windowVisibility)
            )
        )
    }
}

struct InstallerLifecycleDiagnostic: Codable, Sendable {
    let phase: String
    let isActive: Bool
    let isTerminal: Bool
    let installerID: String
    let hasLastError: Bool
}

struct RuntimeDiagnostic: Codable, Sendable {
    let sourceType: String?
    let exactVersion: String?
    let architecture: String?
    let isUsable: Bool?
    let capabilities: [String]
    let failureCodes: [String]
    let realLoadHealthy: Bool
    let realLoadStatus: String?
}

struct PrefixAcquisitionDiagnostic: Codable, Sendable {
    let source: String?
    let canonicalPrefixValid: Bool
    let canonicalSteamPresent: Bool
    let adoptionCandidateCount: Int
    let adoptionResult: String?
    let signatureValid: Bool
    let signatureDriveC: Bool
    let signatureDosdevices: Bool
    let signatureSymlinkResolves: Bool
    let signatureSteamExe: Bool
    let evidenceBound: Bool
}

struct SteamPayloadDiagnostic: Codable, Sendable {
    let lifecycle: String
    let exePresent: Bool
    let exeNonEmpty: Bool
    let installerRunning: Bool
    let steamInstalled: Bool
    let installState: String?
    let canLaunch: Bool
}

struct SupervisedSessionDiagnostic: Codable, Sendable {
    let state: String
    let isRunning: Bool
    let isStopping: Bool
    let needsRecovery: Bool
    let purpose: String?
    let recipeID: String?
    let sessionAgeSeconds: Double?
}

struct WineProcessCensusDiagnostic: Codable, Sendable {
    let hostProcessCount: Int
    let zombieCount: Int
    let orphanCount: Int
    let totalLive: Int
    let censusError: String?
    let hostProcessProof: String
    let liveDescendants: Int
    let liveOrphans: Int
    let exitedCount: Int
    let pidReuseCount: Int
    let unresolvedOutcomes: Int
    let silentSnapshotDrops: Int

    init(
        hostProcessCount: Int,
        zombieCount: Int,
        orphanCount: Int,
        totalLive: Int,
        censusError: String?,
        hostProcessProof: String,
        liveDescendants: Int = 0,
        liveOrphans: Int = 0,
        exitedCount: Int = 0,
        pidReuseCount: Int = 0,
        unresolvedOutcomes: Int = 0,
        silentSnapshotDrops: Int = 0
    ) {
        self.hostProcessCount = hostProcessCount
        self.zombieCount = zombieCount
        self.orphanCount = orphanCount
        self.totalLive = totalLive
        self.censusError = censusError
        self.hostProcessProof = hostProcessProof
        self.liveDescendants = liveDescendants
        self.liveOrphans = liveOrphans
        self.exitedCount = exitedCount
        self.pidReuseCount = pidReuseCount
        self.unresolvedOutcomes = unresolvedOutcomes
        self.silentSnapshotDrops = silentSnapshotDrops
    }

    /// Map a fail-closed census result into the diagnostic shape.
    /// Proof is derived from the census state — never hardcoded. Provider
    /// completeness is carried through: any ambiguous outcome or silent drop is
    /// reflected here.
    init(census: ProcessCensusResult) {
        self.init(
            hostProcessCount: census.liveDescendants,
            zombieCount: census.zombieCount,
            orphanCount: census.liveOrphans,
            totalLive: census.totalLive,
            censusError: census.error?.errorDescription,
            hostProcessProof: census.state == .proven ? "proven" : "notProven",
            liveDescendants: census.liveDescendants,
            liveOrphans: census.liveOrphans,
            exitedCount: census.exitedCount,
            pidReuseCount: census.pidReuseCount,
            unresolvedOutcomes: census.unresolvedOutcomes,
            silentSnapshotDrops: census.silentSnapshotDrops
        )
    }
}

struct WineserverDiagnostic: Codable, Sendable {
    let state: String
}

struct WindowInventoryDiagnostic: Codable, Sendable {
    let windowCount: Int
    let visibility: String
}

struct BoundedOutputDiagnostic: Codable, Sendable {
    let lineCount: Int
    let truncated: Bool
    let lines: [String]
}

struct FailureClassificationDiagnostic: Codable, Sendable {
    let errorCase: String?
    let hasError: Bool
    let setupState: String
}

struct CleanupDiagnostic: Codable, Sendable {
    let cleanupProof: String
    let hostProcessProof: String
    let windowVisibility: String
}

// MARK: - Size limits

enum DiagnosticSizeLimits {
    static let maxBundleBytes = 256 * 1024
    static let maxArrayElements = 50
    static let maxOutputLines = 100
    static let maxStringChars = 500
}

// MARK: - Central sanitizer

enum DiagnosticRedactor {
    private static let sensitivePatterns: [(String, String)] = {
        let ghToken = "gh" + "p_"
        return [
            (ghToken + #"[A-Za-z0-9]+"#, "***"),
            (#"AKI[A][0-9A-Z]{16}"#, "***"),
            (#"xox[baprs]-[A-Za-z0-9][A-Za-z0-9-]+"#, "***"),
            (#"Bearer\s+[A-Za-z0-9._-]+"#, "***"),
            (#"access_token[=:]\s*\S+"#, "***"),
            (#"(?i)password[=:\s]\s*\S+"#, "***"),
            (#"(?i)cookie[=:\s]\s*\S+"#, "***"),
            (#"(?i)authorization[=:\s]\s*\S+"#, "***"),
            (#"(?i)steamguard[=:\s]\s*\S+"#, "***"),
            (#"(?i)sessionid[=:\s]\s*\S+"#, "***"),
            (#"(?i)machineauth[=:\s]\s*\S+"#, "***"),
            (#"(?i)--password[=\s]\s*\S+"#, "***"),
            (#"(?i)--token[=\s]\s*\S+"#, "***"),
            (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, "***@***.***"),
        ]
    }()

    private static let credentialAssignmentPatterns: [String] = [
        #"(?i)[A-Z_]*SECRET[A-Z_]*[=:]\s*\S+"#,
        #"(?i)[A-Z_]*API_KEY[=:]\s*\S+"#,
        #"(?i)\bTOKEN[=:\s]\s*\S+"#,
        #"(?i)PASSWORD[=:\s]\s*\S+"#,
        #"(?i)STEAM_PASSWORD[=:\s]\s*\S+"#,
        #"(?i)COOKIE[=:\s]\s*\S+"#,
        #"(?i)AUTHORIZATION[=:\s]\s*\S+"#,
        #"(?i)SESSIONID[=:\s]\s*\S+"#,
        #"(?i)MACHINEAUTH[=:\s]\s*\S+"#,
        #"(?i)--password[=\s]\s*\S+"#,
        #"(?i)--token[=\s]\s*\S+"#,
    ]

    static func sanitize(_ text: String) -> String {
        var result = PathRedactor.redactPath(text)
        let user = NSUserName()
        if !user.isEmpty {
            result = result.replacingOccurrences(of: user, with: "<user>")
        }
        for (pattern, replacement) in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }
        result = PathRedactor.maskHostnames(result)
        if result.hasPrefix("/") {
            result = "<path>"
        }
        if result.count > DiagnosticSizeLimits.maxStringChars {
            result = String(result.prefix(DiagnosticSizeLimits.maxStringChars)) + "…"
        }
        return result
    }

    static func sanitizeArray(_ items: [String]) -> [String] {
        Array(items.prefix(DiagnosticSizeLimits.maxArrayElements)).map { sanitize($0) }
    }

    static func redactLines(_ text: String) -> [String] {
        let allLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let bounded = Array(allLines.suffix(DiagnosticSizeLimits.maxOutputLines))
        return bounded.map { sanitize($0) }
    }

    static func scanForCredentialAssignments(_ text: String) -> [String] {
        var found: [String] = []
        for pattern in credentialAssignmentPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                found.append(pattern)
            }
        }
        return found
    }

    static func scanForViolations(_ json: String) -> [String] {
        var violations: [String] = []
        let home = NSHomeDirectory()
        if json.contains(home) { violations.append("raw_home_path") }
        let user = NSUserName()
        if !user.isEmpty && json.contains(user) { violations.append("raw_username") }
        if PathRedactor.containsPrivateKey(json) { violations.append("private_key") }
        let ghPrefix = "gh" + "p_"
        let tokenPatterns = [ghPrefix + #"[A-Za-z0-9]+"#, #"AKI[A][0-9A-Z]{16}"#, #"xox[baprs]-"#]
        for pattern in tokenPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)) != nil {
                violations.append("token_pattern")
                break
            }
        }
        let credHits = scanForCredentialAssignments(json)
        if !credHits.isEmpty { violations.append("credential_assignment") }
        return violations
    }
}

// MARK: - Trusted diagnostics root

enum DiagnosticTrustedRoot {
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Diagnostics")
    }

    static let maxFilenameLength = 255

    static func validatedTarget(filename: String) throws -> URL {
        try validateFilename(filename)
        try validateFullPathChain()
        let target = root.appendingPathComponent(filename)
        try validateDestination(target)
        return target
    }

    static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename.count <= maxFilenameLength else {
            throw DiagnosticBundleWriter.WriteError.pathTraversal
        }
        guard !filename.contains("..") else {
            throw DiagnosticBundleWriter.WriteError.pathTraversal
        }
        guard !filename.contains("/"), !filename.contains("\\") else {
            throw DiagnosticBundleWriter.WriteError.pathTraversal
        }
        guard !filename.hasPrefix("/") else {
            throw DiagnosticBundleWriter.WriteError.pathTraversal
        }
        guard filename == (filename as NSString).lastPathComponent else {
            throw DiagnosticBundleWriter.WriteError.pathTraversal
        }
        for scalar in filename.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw DiagnosticBundleWriter.WriteError.pathTraversal
            }
        }
    }

    static func validateFullPathChain() throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let relativePath = root.path.replacingOccurrences(of: home, with: "")
        let components = relativePath.components(separatedBy: "/").filter { !$0.isEmpty }
        var current = URL(fileURLWithPath: home)
        if (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil {
            throw DiagnosticBundleWriter.WriteError.symlinkRejected
        }
        for component in components {
            current = current.appendingPathComponent(component)
            if (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw DiagnosticBundleWriter.WriteError.symlinkRejected
            }
            if fm.fileExists(atPath: current.path) {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: current.path, isDirectory: &isDir), isDir.boolValue else {
                    throw DiagnosticBundleWriter.WriteError.notRegularDirectory
                }
            }
        }
    }

    static func validateDestination(_ target: URL) throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            throw DiagnosticBundleWriter.WriteError.symlinkRejected
        }
        if fm.fileExists(atPath: target.path) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: target.path, isDirectory: &isDir)
            if isDir.boolValue {
                throw DiagnosticBundleWriter.WriteError.notRegularFile
            }
            let attrs = try? fm.attributesOfItem(atPath: target.path)
            if let type = attrs?[.type] as? FileAttributeType,
               type != .typeRegular {
                throw DiagnosticBundleWriter.WriteError.notRegularFile
            }
        }
    }

    static func revalidateBeforeWrite(_ target: URL) throws {
        try validateFullPathChain()
        try validateDestination(target)
    }
}

// MARK: - Atomic writer

enum DiagnosticBundleWriter {
    enum WriteError: LocalizedError {
        case symlinkRejected
        case directoryEscape
        case pathTraversal
        case notRegularDirectory
        case notRegularFile
        case destinationExists
        case redactionViolation([String])
        case sizeExceeded(Int)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .symlinkRejected: return "Symlink detected in path chain"
            case .directoryEscape: return "Target path escapes trusted root"
            case .pathTraversal: return "Path traversal detected"
            case .notRegularDirectory: return "Path component is not a regular directory"
            case .notRegularFile: return "Target is not a regular file"
            case .destinationExists: return "Destination already exists — refusing to replace"
            case .redactionViolation(let v): return "Redaction violations: \(v.joined(separator: ", "))"
            case .sizeExceeded(let n): return "Bundle size \(n) exceeds limit"
            case .encodingFailed: return "JSON encoding failed"
            }
        }
    }

    static func write(_ bundle: DiagnosticBundle, to targetURL: URL) throws {
        let fm = FileManager.default
        let parent = targetURL.deletingLastPathComponent()
        let isTrusted = targetURL.path.hasPrefix(DiagnosticTrustedRoot.root.path)

        if isTrusted {
            try DiagnosticTrustedRoot.validateFullPathChain()
        } else {
            if (try? fm.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                throw WriteError.symlinkRejected
            }
        }
        try DiagnosticTrustedRoot.validateDestination(targetURL)

        let sanitized = bundle.sanitized()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sanitized) else {
            throw WriteError.encodingFailed
        }

        guard data.count <= DiagnosticSizeLimits.maxBundleBytes else {
            throw WriteError.sizeExceeded(data.count)
        }

        guard let json = String(data: data, encoding: .utf8) else {
            throw WriteError.encodingFailed
        }
        let violations = DiagnosticRedactor.scanForViolations(json)
        guard violations.isEmpty else {
            throw WriteError.redactionViolation(violations)
        }

        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        if isTrusted {
            try DiagnosticTrustedRoot.validateFullPathChain()
        }

        if fm.fileExists(atPath: targetURL.path) {
            throw WriteError.destinationExists
        }

        if isTrusted {
            try DiagnosticTrustedRoot.revalidateBeforeWrite(targetURL)
        }

        let tempURL = parent.appendingPathComponent(".diagnostic-bundle-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

            if isTrusted {
                try DiagnosticTrustedRoot.validateFullPathChain()
            }

            try fm.moveItem(at: tempURL, to: targetURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }
}
