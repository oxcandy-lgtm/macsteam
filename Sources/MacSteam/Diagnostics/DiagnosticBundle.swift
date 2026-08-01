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
    let hostProcessProof: String
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

// MARK: - Redaction

enum DiagnosticRedactor {
    static func redact(_ text: String) -> String {
        var result = PathRedactor.fullyRedact(text)
        let user = NSUserName()
        if !user.isEmpty {
            result = result.replacingOccurrences(of: user, with: "<user>")
        }
        if result.count > DiagnosticSizeLimits.maxStringChars {
            result = String(result.prefix(DiagnosticSizeLimits.maxStringChars)) + "…"
        }
        return result
    }

    static func redactLines(_ text: String) -> [String] {
        let allLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let bounded = Array(allLines.suffix(DiagnosticSizeLimits.maxOutputLines))
        return bounded.map { redact($0) }
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
        return violations
    }
}

// MARK: - Atomic writer

enum DiagnosticBundleWriter {
    enum WriteError: LocalizedError {
        case symlinkRejected
        case directoryEscape
        case redactionViolation([String])
        case sizeExceeded(Int)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .symlinkRejected: return "Target path is a symlink"
            case .directoryEscape: return "Target path escapes allowed directory"
            case .redactionViolation(let v): return "Redaction violations: \(v.joined(separator: ", "))"
            case .sizeExceeded(let n): return "Bundle size \(n) exceeds limit"
            case .encodingFailed: return "JSON encoding failed"
            }
        }
    }

    static func write(_ bundle: DiagnosticBundle, to targetURL: URL) throws {
        let fm = FileManager.default

        if (try? fm.destinationOfSymbolicLink(atPath: targetURL.path)) != nil {
            throw WriteError.symlinkRejected
        }

        let parent = targetURL.deletingLastPathComponent()
        let canonicalParent = parent.resolvingSymlinksInPath()
        let canonicalTarget = targetURL.resolvingSymlinksInPath()
        guard canonicalTarget.path.hasPrefix(canonicalParent.path + "/") else {
            throw WriteError.directoryEscape
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle) else {
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
        let tempURL = parent.appendingPathComponent(".diagnostic-bundle-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        try fm.moveItem(at: tempURL, to: targetURL)
    }
}
