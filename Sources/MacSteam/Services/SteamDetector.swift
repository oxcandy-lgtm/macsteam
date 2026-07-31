// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Detects Steam installations and distinguishes between the native
/// macOS client and a Windows Steam installation inside a compatibility
/// runtime (e.g., CrossOver bottles).
class SteamDetector: @unchecked Sendable {

    // MARK: - Detection result

    enum SteamDetectionResult: Equatable, Sendable {
        /// Windows Steam was found inside a runtime bottle.
        case windowsSteamFound(URL)
        /// Only the native macOS Steam is present.
        case nativeMacSteamOnly
        /// No Steam installation was detected.
        case noSteamFound
    }

    // MARK: - Public API

    /// Detect Windows Steam inside a given runtime.
    func detectWindowsSteam(in runtime: any CompatibilityRuntime) -> SteamDetectionResult {
        guard let crossover = runtime as? CrossOverRuntime else {
            return .noSteamFound
        }

        // Use CrossOverRuntime's bottle discovery
        if let (_, steamURL) = crossover.findSteamBottle() {
            return .windowsSteamFound(steamURL)
        }

        // Check if native macOS Steam is installed
        let nativeSteamPath = "/Applications/Steam.app"
        if FileManager.default.fileExists(atPath: nativeSteamPath) {
            return .nativeMacSteamOnly
        }

        return .noSteamFound
    }

    /// Inspect a specific game's installation status within a Windows Steam
    /// installation.
    func inspectGame(_ recipe: GameRecipe, windowsSteamURL: URL) -> GameInspection {
        // Steam root is the parent directory of steam.exe
        let steamRoot = windowsSteamURL.deletingLastPathComponent()

        let manifestPath = steamRoot
            .appendingPathComponent("steamapps")
            .appendingPathComponent(recipe.detection.manifestName)

        let manifestPresent = FileManager.default.fileExists(atPath: manifestPath.path)

        // Resolve install directory from manifest
        let installDirectoryResolved: Bool
        let executablePresent: Bool

        if manifestPresent {
            // Try to read the manifest for install dir
            if let manifestContent = try? String(contentsOf: manifestPath, encoding: .utf8),
               let installDir = extractInstallDir(from: manifestContent) {

                let gameDir = steamRoot
                    .appendingPathComponent("steamapps/common")
                    .appendingPathComponent(installDir)

                installDirectoryResolved = FileManager.default
                    .fileExists(atPath: gameDir.path)

                // Check for game executable using recipe candidates or fallback
                executablePresent = checkForGameExecutable(
                    in: gameDir,
                    candidates: recipe.detection.executableCandidates
                )
            } else {
                installDirectoryResolved = false
                executablePresent = false
            }
        } else {
            installDirectoryResolved = false
            executablePresent = false
        }

        let isReady = manifestPresent && installDirectoryResolved && executablePresent

        return GameInspection(
            recipeID: recipe.id,
            steamPresent: true,
            isWindowsSteam: true,
            manifestPresent: manifestPresent,
            installDirectoryResolved: installDirectoryResolved,
            executablePresent: executablePresent,
            isReady: isReady
        )
    }

    /// Check whether the native macOS Steam client is installed.
    func isNativeMacSteamInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Steam.app")
    }

    // MARK: - Private helpers

    /// Extract the install directory name from an ACF manifest.
    private func extractInstallDir(from manifest: String) -> String? {
        let patterns = [
            #"\"installdir\"\s+\"([^\"]+)\""#,
            #"\"installDir\"\s+\"([^\"]+)\""#,
            #"\"InstallDir\"\s+\"([^\"]+)\""#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(
                in: manifest,
                range: NSRange(manifest.startIndex..., in: manifest)
               ) {
                let range = match.range(at: 1)
                if let swiftRange = Range(range, in: manifest) {
                    return String(manifest[swiftRange])
                }
            }
        }
        return nil
    }

    /// Check for game executables in a directory.
    private func checkForGameExecutable(in directory: URL, candidates: [String]?) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        if let candidates, !candidates.isEmpty {
            return candidates.contains { contents.contains($0) }
        }
        // Fallback: any .exe file
        return contents.contains { $0.hasSuffix(".exe") }
    }
}
