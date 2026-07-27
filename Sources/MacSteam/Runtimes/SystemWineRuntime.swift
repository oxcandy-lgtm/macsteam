// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// System-installed Wine runtime detection via common macOS paths.
///
/// Scans standard locations (Homebrew, MacPorts, system PATH) for an
/// existing Wine installation. This adapter is **read-only**: MacSteam
/// never modifies a system Wine installation.
///
/// Priority: lowest among Wine runtimes.
final class SystemWineRuntime: @unchecked Sendable {
    static let runtimeID = "system-wine"

    let runtimeURL: URL
    private let fm = FileManager.default

    /// Standard locations where Wine may be installed on macOS.
    private static let probeLocations: [URL] = [
        URL(fileURLWithPath: "/usr/local/bin"),
        URL(fileURLWithPath: "/opt/homebrew/bin"),
        URL(fileURLWithPath: "/opt/local/bin"),
    ]

    init?(url: URL) {
        let resolved = url.standardized
        // Verify wine exists at this location
        let wineExe = resolved.appendingPathComponent("wine")
        guard fm.isExecutableFile(atPath: wineExe.path) else { return nil }
        self.runtimeURL = resolved
    }

    static func detectSystem() -> Bool {
        let fm = FileManager.default
        return probeLocations.contains { url in
            fm.isExecutableFile(atPath: url.appendingPathComponent("wine").path)
        }
    }

    func inspect() -> RuntimeInspection {
        var failures: [RuntimeFailure] = []

        let wine = runtimeURL.appendingPathComponent("wine")
        guard fm.isExecutableFile(atPath: wine.path) else {
            failures.append(RuntimeFailure(code: .executableMissing, message: "wine not found"))
            return RuntimeInspection(runtimeID: Self.runtimeID, isUsable: false, failures: failures)
        }

        let wineserver = runtimeURL.appendingPathComponent("wineserver")
        if !fm.isExecutableFile(atPath: wineserver.path) {
            failures.append(RuntimeFailure(code: .wineserverMissing, message: "wineserver not found"))
        }

        let version = probeVersion(wine: wine)

        return RuntimeInspection(
            runtimeID: Self.runtimeID,
            version: version,
            architecture: "x86_64",
            isUsable: failures.isEmpty,
            capabilities: failures.isEmpty ? [.windowsProcess, .isolatedPrefix] : [],
            failures: failures
        )
    }

    func launchPlan(for recipe: GameRecipe) -> LaunchPlan? {
        let wine = runtimeURL.appendingPathComponent("wine")
        guard fm.isExecutableFile(atPath: wine.path) else { return nil }

        let prefixDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/\(recipe.prefix.id)/prefix")

        return LaunchPlan(
            runtimeExecutable: wine,
            arguments: recipe.launch.storeArguments,
            mode: .detached,
            environment: ["WINEPREFIX": prefixDir.path],
            workingDirectory: prefixDir,
            boundary: ExecutionBoundary(
                allowedPrefixRoot: prefixDir,
                allowedRuntimeRoots: [runtimeURL],
                allowedEnvironmentKeys: []
            )
        )
    }

    // MARK: - Private

    private func probeVersion(wine: URL) -> String? {
        let process = Process()
        process.executableURL = wine
        process.arguments = ["--version"]

        let outPipe = Pipe()
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

// MARK: - CompatibilityRuntime conformance

extension SystemWineRuntime: CompatibilityRuntime {
    func validate() throws {
        let wine = runtimeURL.appendingPathComponent("wine")
        guard fm.isExecutableFile(atPath: wine.path) else {
            throw RuntimeFailure(code: .executableMissing, message: "wine not found at \(runtimeURL.path)")
        }
    }
}

// MARK: - WineRuntimeControl conformance

extension SystemWineRuntime: WineRuntimeControl {
    var wineserverExecutable: URL {
        runtimeURL.appendingPathComponent("wineserver")
    }

    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw WineServerError.prefixNotFound(prefix)
        }
        return SafeProcessEnvironment.base.merging([
            "WINEPREFIX": prefix.path
        ]) { _, new in new }
    }
}
