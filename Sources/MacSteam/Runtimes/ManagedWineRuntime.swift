// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Managed Wine runtime — MacSteam's own curated Wine distribution.
///
/// In U1 this is a **contract-only implementation**: no binary distribution
/// is performed.  `inspect()` always returns `isUsable: false` unless a
/// valid activation receipt is present, which is impossible in U1.
///
/// Storage layout (future):
/// ```
/// ~/Library/Application Support/MacSteam/Runtimes/
/// └── <runtime-id>/
///     ├── manifest.json
///     ├── runtime/
///     ├── licenses/
///     ├── notices/
///     ├── source-identity.json
///     └── receipt.json
/// ```
///
/// Installation pipeline (future):
/// ```
/// download/import → archive SHA-256 → manifest schema → license completeness
/// → file inventory → symlink bounds → executable inventory → atomic activation
/// ```
///
/// Priority: highest among Wine runtimes.
final class ManagedWineRuntime: @unchecked Sendable {
    static let runtimeID = "managed-wine"

    /// Root directory for all managed runtimes.
    static let runtimesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/MacSteam/Runtimes")

    let runtimeURL: URL
    private let fm = FileManager.default

    init?(url: URL) {
        // Use canonical component comparison, NOT hasPrefix on path strings
        guard url.standardized.pathComponents.starts(with: Self.runtimesRoot.standardized.pathComponents) else {
            return nil
        }
        guard fm.fileExists(atPath: url.path) else { return nil }
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { return nil }
        self.runtimeURL = url
    }

    static func detectSystem() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtimesRoot.path) else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: runtimesRoot.path) else {
            return false
        }
        // Must have at least one non-JSON entry (manifest-only dirs don't count)
        let validEntries = contents.filter { entry in
            let entryURL = runtimesRoot.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryURL.path, isDirectory: &isDir), isDir.boolValue else { return false }
            let manifestURL = entryURL.appendingPathComponent("manifest.json")
            let receiptURL = entryURL.appendingPathComponent("receipt.json")
            return fm.fileExists(atPath: manifestURL.path) && fm.fileExists(atPath: receiptURL.path)
        }
        return !validEntries.isEmpty
    }

    func inspect() -> RuntimeInspection {
        // U1: contract-only — managed runtime activation is impossible.
        // All the scaffold below is dead code for future use; inspect()
        // always returns isUsable: false in U1.
        guard isActivated() else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(
                    code: .invalidManifest,
                    message: "U1_MANAGED_RUNTIME_NOT_ACTIVATED"
                )]
            )
        }

        let manifestURL = runtimeURL.appendingPathComponent("manifest.json")
        let sourceIdentityURL = runtimeURL.appendingPathComponent("source-identity.json")

        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RuntimeArtifactManifest.self, from: manifestData) else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(code: .invalidManifest, message: "manifest.json missing or invalid")]
            )
        }

        guard manifest.isValid else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(code: .invalidManifest, message: "manifest.json failed validation")]
            )
        }

        let hasMissingLicense = manifest.license.licenseFiles.contains { fname in
            !fm.fileExists(atPath: runtimeURL.appendingPathComponent("licenses/\(fname)").path)
        }
        if hasMissingLicense {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(code: .missingLicense, message: "License files missing")]
            )
        }

        guard fm.fileExists(atPath: sourceIdentityURL.path) else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(code: .missingLicense, message: "source-identity.json missing")]
            )
        }

        let wineExe = runtimeURL.appendingPathComponent("runtime/bin/wine")
        guard fm.isExecutableFile(atPath: wineExe.path) else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(code: .executableMissing, message: "runtime/bin/wine not found")]
            )
        }

        return RuntimeInspection(
            runtimeID: Self.runtimeID,
            version: manifest.version,
            architecture: manifest.runtimeArchitectures.first?.arch,
            isUsable: true,
            capabilities: manifest.capabilities
        )
    }

    func launchPlan(for recipe: GameRecipe) -> LaunchPlan? {
        guard isActivated() else { return nil }
        let wineExe = runtimeURL.appendingPathComponent("runtime/bin/wine")
        guard fm.isExecutableFile(atPath: wineExe.path) else { return nil }

        let prefixDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/\(recipe.prefix.id)")

        return LaunchPlan(
            runtimeExecutable: wineExe,
            arguments: recipe.launch.storeArguments,
            mode: .detached,
            environment: ["WINEPREFIX": prefixDir.path],
            workingDirectory: prefixDir,
            boundary: ExecutionBoundary(
                allowedPrefixRoot: prefixDir,
                allowedRuntimeRoots: [runtimeURL.appendingPathComponent("runtime")],
                allowedEnvironmentKeys: []
            )
        )
    }

    // MARK: - Private

    /// U1: always returns false.  In a future release this will check for a
    /// valid activation receipt after passing the full installation pipeline:
    ///
    /// canonical runtime root → manifest schema valid → manifest SHA valid →
    /// source identity valid → license files complete → notice files complete →
    /// runtime inventory valid → symlink bounds valid → world-writable files zero →
    /// wine/wineserver/wineboot verified → activation receipt valid → atomic activation
    private func isActivated() -> Bool {
        let receiptURL = runtimeURL.appendingPathComponent("receipt.json")
        guard fm.fileExists(atPath: receiptURL.path) else { return false }
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(OperationReceipt.self, from: data) else {
            return false
        }
        return receipt.result == .success
    }
}

// MARK: - CompatibilityRuntime conformance

extension ManagedWineRuntime: CompatibilityRuntime {
    func validate() throws {
        // U1: not available unless activated via receipt
        guard isActivated() else {
            throw RuntimeFailure(code: .invalidManifest, message: "U1_MANAGED_RUNTIME_NOT_ACTIVATED")
        }
        let manifestURL = runtimeURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RuntimeFailure(code: .invalidManifest, message: "Managed runtime manifest not found")
        }
    }
}
