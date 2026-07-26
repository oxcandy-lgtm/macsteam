// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Detects a game's installation within a Wine prefix by checking for
/// the Steam manifest file and executable.
final class SteamInstallationDetector: @unchecked Sendable {
    private let fm = FileManager.default

    /// Inspect the game installation status within the runtime's prefix.
    func inspect(recipe: GameRecipe, runtime: any CompatibilityRuntime) async -> GameInspection {
        let prefixDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/\(recipe.prefix.id)/prefix")

        let steamRoot = prefixDir.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let steamAlt = prefixDir.appendingPathComponent("drive_c/Program Files/Steam")

        // Determine which steam directory exists
        let steamDir: URL
        if fm.fileExists(atPath: steamRoot.path) {
            steamDir = steamRoot
        } else if fm.fileExists(atPath: steamAlt.path) {
            steamDir = steamAlt
        } else {
            return GameInspection(
                recipeID: recipe.id,
                steamPresent: false,
                isWindowsSteam: false,
                manifestPresent: false,
                installDirectoryResolved: false,
                executablePresent: false,
                isReady: false
            )
        }

        // Check for steam executable
        let steamExe = steamDir.appendingPathComponent("steam.exe")
        let steamPresent = fm.fileExists(atPath: steamExe.path)

        // Check for game manifest in steamapps
        let manifestPath = steamDir
            .appendingPathComponent("steamapps")
            .appendingPathComponent(recipe.detection.manifestName)
        let manifestPresent = fm.fileExists(atPath: manifestPath.path)

        // Try to resolve install directory from manifest
        var installDirectoryResolved = false
        var executablePresent = false

        if manifestPresent,
           let manifestContent = try? String(contentsOf: manifestPath, encoding: .utf8),
           let installDirName = extractInstallDir(from: manifestContent) {

            let gameDir = steamDir
                .appendingPathComponent("steamapps/common")
                .appendingPathComponent(installDirName)
            installDirectoryResolved = fm.fileExists(atPath: gameDir.path)

            executablePresent = recipe.detection.executableCandidates.contains { candidate in
                let exeURL = gameDir.appendingPathComponent(candidate)
                return fm.fileExists(atPath: exeURL.path)
            }
        }

        let isReady = manifestPresent && installDirectoryResolved && executablePresent

        return GameInspection(
            recipeID: recipe.id,
            steamPresent: steamPresent,
            isWindowsSteam: steamPresent,
            manifestPresent: manifestPresent,
            installDirectoryResolved: installDirectoryResolved,
            executablePresent: executablePresent,
            isReady: isReady
        )
    }

    // MARK: - Private

    private func extractInstallDir(from manifest: String) -> String? {
        let patterns = [
            #"\"installdir\"\s+\"([^\"]+)\""#,
            #"\"installDir\"\s+\"([^\"]+)\""#,
            #"\"InstallDir\"\s+\"([^\"]+)\""#,
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
}
