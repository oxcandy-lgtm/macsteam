// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// CrossOver runtime adapter — optional fallback in the runtime priority chain.
///
/// Detects an existing CrossOver.app installation and provides Wine-based
/// process execution through its bundled `wine` CLI tool.
///
/// CrossOver binaries are never copied or bundled. MacSteam only detects
/// and uses an existing installation.
final class CrossOverRuntime: @unchecked Sendable {
    static let runtimeID = "crossover"

    let bundleURL: URL
    private let fm = FileManager.default

    init?(url: URL) {
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        guard bundleID == "com.codeweavers.CrossOver" else { return nil }
        self.bundleURL = url
    }

    /// Detect CrossOver.app at standard locations.
    static func detectSystem() -> Bool {
        let candidates = [
            URL(fileURLWithPath: "/Applications/CrossOver.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/CrossOver.app"),
        ]
        return candidates.contains { url in
            Bundle(url: url)?.bundleIdentifier == "com.codeweavers.CrossOver"
        }
    }

    func inspect() -> RuntimeInspection {
        let bundleID = Bundle(url: bundleURL)?.bundleIdentifier ?? ""
        guard bundleID == "com.codeweavers.CrossOver" else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                displayName: "CrossOver",
                isUsable: false,
                failures: [RuntimeFailure(code: .executableMissing, message: "CrossOver bundle not valid")]
            )
        }

        guard wineExecutable != nil else {
            return RuntimeInspection(
                runtimeID: Self.runtimeID,
                displayName: "CrossOver",
                isUsable: false,
                failures: [RuntimeFailure(code: .executableMissing, message: "wine CLI not found in CrossOver bundle")]
            )
        }

        let version = Bundle(url: bundleURL)?.infoDictionary?["CFBundleShortVersionString"] as? String

        return RuntimeInspection(
            runtimeID: Self.runtimeID,
            displayName: "CrossOver",
            version: version,
            isUsable: true,
            capabilities: [.windowsProcess, .isolatedPrefix]
        )
    }

    func launchPlan(for recipe: GameRecipe) -> LaunchPlan? {
        guard let wine = wineExecutable else { return nil }
        guard let bottleName = try? resolveSteamBottleName() else { return nil }

        return LaunchPlan(
            runtimeExecutable: wine,
            arguments: [
                "--bottle", bottleName,
                "--cx-app", "steam.exe",
            ] + recipe.launch.storeArguments,
            mode: .detached,
            environment: [:],
            workingDirectory: nil,
            boundary: ExecutionBoundary(
                allowedPrefixRoot: bundleURL,
                allowedRuntimeRoots: [bundleURL.appendingPathComponent("Contents/SharedSupport/CrossOver/bin")],
                allowedEnvironmentKeys: []
            )
        )
    }

    func validate() throws {
        guard Bundle(url: bundleURL)?.bundleIdentifier == "com.codeweavers.CrossOver" else {
            throw RuntimeFailure(code: .bundleNotValid, message: "CrossOver bundle not valid")
        }
    }

    // MARK: - Private

    private var wineExecutable: URL? {
        let candidate = bundleURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
        guard fm.isExecutableFile(atPath: candidate.path) else { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return candidate
    }

    private func resolveSteamBottleName() throws -> String {
        // Simplified bottle discovery — expand as needed
        throw RuntimeFailure(code: .runtimeRootNotFound, message: "CrossOver bottle discovery not yet migrated to U1")
    }
}

// MARK: - CompatibilityRuntime conformance

extension CrossOverRuntime: CompatibilityRuntime {}