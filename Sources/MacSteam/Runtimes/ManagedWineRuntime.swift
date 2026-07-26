// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Managed Wine runtime — MacSteam's own curated Wine distribution.
///
/// In U1 this is a **contract-only implementation**: no binary distribution
/// is performed. The scaffold defines the storage layout and installation
/// pipeline that will be activated in a future release.
///
/// Storage layout:
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
        guard url.path.hasPrefix(Self.runtimesRoot.path) else { return nil }
        guard fm.fileExists(atPath: url.path) else { return nil }
        // Check for manifest.json as the marker of a valid managed runtime
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
        return contents.contains { $0.hasSuffix(".json") == false }
    }

    func inspect() -> RuntimeInspection {
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

        // Verify license artifacts exist
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

        // Verify source identity
        guard fm.fileExists(atPath: sourceIdentityURL.path) else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                isUsable: false,
                failures: [RuntimeFailure(code: .missingLicense, message: "source-identity.json missing")]
            )
        }

        // Check wine executables
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
        let wineExe = runtimeURL.appendingPathComponent("runtime/bin/wine")
        guard fm.isExecutableFile(atPath: wineExe.path) else { return nil }

        let prefixDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/\(recipe.prefix.id)/prefix")

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
}

// MARK: - CompatibilityRuntime conformance

extension ManagedWineRuntime: CompatibilityRuntime {
    func validate() throws {
        let manifestURL = runtimeURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RuntimeFailure(code: .invalidManifest, message: "Managed runtime manifest not found")
        }
    }
}
