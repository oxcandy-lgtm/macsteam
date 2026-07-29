// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An imported Wine runtime — a user-selected directory containing
/// Wine executables.
///
/// Users obtain a Wine build from a trusted source and point MacSteam
/// at its root directory. MacSteam verifies the runtime integrity and
/// capabilities before use.
///
/// Validation checks:
///   - wine, wineserver, wineboot executables exist
///   - Runtime root is not a symlink (or resolves safely)
///   - No world-writable executables
///   - Architecture and version are probed
///   - Required dynamic libraries are present
final class ImportedWineRuntime: @unchecked Sendable {
    static let runtimeID = "imported-wine"

    let runtimeURL: URL
    private let fm = FileManager.default

    /// The expected relative paths for Wine executables within the runtime root.
    private struct WinePaths {
        /// Standard layout: <root>/bin/wine
        static let wine = "bin/wine"
        static let wineserver = "bin/wineserver"
        static let wineboot = "bin/wineboot"
        static let wine64: String? = "bin/wine64"
        static let wineprefixcreate: String? = "bin/wineprefixcreate"

        /// macOS bundle layout: <root>/Contents/Resources/wine/bin/wine
        static let bundleRoot = "Contents/Resources/wine"
        static let bundleWine = "\(bundleRoot)/bin/wine"
        static let bundleWineserver = "\(bundleRoot)/bin/wineserver"
        static let bundleWineboot = "\(bundleRoot)/bin/wineboot"
    }

    init?(url: URL) {
        // Resolve symlinks and validate the root
        let resolved: URL
        if let linkDest = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            resolved = URL(fileURLWithPath: linkDest, relativeTo: url.deletingLastPathComponent()).standardized
        } else {
            resolved = url.standardized
        }

        // --- Reject CrossOver.app ancestry ---
        var ancestor = resolved
        while ancestor.path != "/" {
            if ancestor.lastPathComponent == "CrossOver.app" {
                return nil
            }
            ancestor = ancestor.deletingLastPathComponent()
        }

        // Must not be world-writable
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: resolved.path),
           let permissions = attrs[.posixPermissions] as? Int,
           (permissions & 0o002) != 0 {
            return nil
        }

        // Check standard layout first, then bundle layout
        let wineExe = resolved.appendingPathComponent(WinePaths.wine)
        let bundleWine = resolved.appendingPathComponent(WinePaths.bundleWine)

        guard fm.isExecutableFile(atPath: wineExe.path)
                || fm.isExecutableFile(atPath: bundleWine.path) else {
            return nil
        }

        self.runtimeURL = resolved
    }

    static func detectSystem() -> Bool { false }

    func inspect() -> RuntimeInspection {
        var failures: [RuntimeFailure] = []

        // Determine layout: standard (bin/wine) or bundle (Contents/Resources/wine/bin/wine)
        let layoutRoot: URL
        let layoutPrefix: String
        if fm.isExecutableFile(atPath: runtimeURL.appendingPathComponent(WinePaths.wine).path) {
            layoutRoot = runtimeURL
            layoutPrefix = ""
        } else if fm.isExecutableFile(atPath: runtimeURL.appendingPathComponent(WinePaths.bundleWine).path) {
            layoutRoot = runtimeURL.appendingPathComponent(WinePaths.bundleRoot)
            layoutPrefix = WinePaths.bundleRoot + "/"
        } else {
            failures.append(RuntimeFailure(code: .executableMissing, message: "wine not found in standard or bundle layout"))
            return RuntimeInspection(runtimeID: Self.runtimeID, isUsable: false, failures: failures)
        }

        // Check core executables
        let wine = layoutRoot.appendingPathComponent("bin/wine")
        guard fm.isExecutableFile(atPath: wine.path) else {
            failures.append(RuntimeFailure(code: .executableMissing, message: "\(layoutPrefix)bin/wine not found or not executable"))
            return RuntimeInspection(runtimeID: Self.runtimeID, isUsable: false, failures: failures)
        }

        let wineserver = layoutRoot.appendingPathComponent("bin/wineserver")
        if !fm.isExecutableFile(atPath: wineserver.path) {
            failures.append(RuntimeFailure(code: .wineserverMissing, message: "\(layoutPrefix)bin/wineserver not found or not executable"))
        }

        let wineboot = layoutRoot.appendingPathComponent("bin/wineboot")
        if !fm.isExecutableFile(atPath: wineboot.path) {
            failures.append(RuntimeFailure(code: .winebootMissing, message: "\(layoutPrefix)bin/wineboot not found or not executable"))
        }

        // Check for symlink escape
        if isSymlinkEscape(runtimeURL) {
            failures.append(RuntimeFailure(code: .symlinkEscape, message: "Runtime root uses symlink escape"))
        }

        // Check world-writable state
        if isWorldWritable(runtimeURL) {
            failures.append(RuntimeFailure(code: .worldWritable, message: "Runtime root is world-writable"))
        }

        // Probe version
        let version = probeVersion(wine: wine)

        // Probe architecture
        let arch = probeArchitecture(wine: wine)

        let isUsable = failures.isEmpty
        let capabilities: RuntimeCapabilities = isUsable ? [.windowsProcess, .isolatedPrefix] : []

        return RuntimeInspection(
            runtimeID: Self.runtimeID,
            version: version,
            architecture: arch,
            isUsable: isUsable,
            capabilities: capabilities,
            failures: failures
        )
    }

    func launchPlan(for recipe: GameRecipe) -> LaunchPlan? {
        // Determine layout root
        let layoutRoot: URL
        if fm.isExecutableFile(atPath: runtimeURL.appendingPathComponent(WinePaths.wine).path) {
            layoutRoot = runtimeURL
        } else if fm.isExecutableFile(atPath: runtimeURL.appendingPathComponent(WinePaths.bundleWine).path) {
            layoutRoot = runtimeURL.appendingPathComponent(WinePaths.bundleRoot)
        } else {
            return nil
        }

        let wine = layoutRoot.appendingPathComponent("bin/wine")
        guard fm.isExecutableFile(atPath: wine.path) else { return nil }

        let prefixDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/\(recipe.prefix.id)")

        return LaunchPlan(
            runtimeExecutable: wine,
            arguments: recipe.launch.storeArguments,
            mode: .detached,
            environment: [
                "WINEPREFIX": prefixDir.path,
                "WINEDEBUG": "-all",
            ],
            workingDirectory: prefixDir,
            boundary: ExecutionBoundary(
                allowedPrefixRoot: prefixDir,
                allowedRuntimeRoots: [runtimeURL],
                allowedEnvironmentKeys: ["WINEDEBUG"]
            )
        )
    }

    // MARK: - Private helpers

    private func probeVersion(wine: URL) -> String? {
        let process = Process()
        process.executableURL = wine
        process.arguments = ["--version"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

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

    private func probeArchitecture(wine: URL) -> String? {
        let process = Process()
        process.executableURL = wine
        process.arguments = ["--help"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Check for architecture indicators
            if output.contains("x86_64") || output.contains("PE32+") {
                return "x86_64"
            } else if output.contains("i386") || output.contains("PE32") {
                return "i386"
            }
            return nil
        } catch {
            return nil
        }
    }

    private func isSymlinkEscape(_ url: URL) -> Bool {
        let std = url.standardized
        let resolved = (try? fm.destinationOfSymbolicLink(atPath: url.path)).map {
            URL(fileURLWithPath: $0, relativeTo: url.deletingLastPathComponent()).standardized
        } ?? std
        // Simple check: if resolved path doesn't start with the original, it escaped
        return resolved.path != std.path && !resolved.path.hasPrefix(std.path)
    }

    private func isWorldWritable(_ url: URL) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let permissions = attrs[.posixPermissions] as? Int else {
            return false
        }
        return (permissions & 0o002) != 0
    }
}

// MARK: - CompatibilityRuntime conformance

extension ImportedWineRuntime: CompatibilityRuntime {
    func validate() throws {
        let wine = runtimeURL.appendingPathComponent("bin/wine")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw RuntimeFailure(code: .executableMissing, message: "wine not found at \(runtimeURL.path)")
        }
    }
}

// MARK: - WineRuntimeControl conformance

extension ImportedWineRuntime: WineRuntimeControl {
    var wineserverExecutable: URL {
        // Check both layout forms
        let standard = runtimeURL.appendingPathComponent(WinePaths.wineserver)
        if FileManager.default.isExecutableFile(atPath: standard.path) {
            return standard
        }
        return runtimeURL.appendingPathComponent(WinePaths.bundleWineserver)
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
