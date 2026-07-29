// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Detects a game's installation state within a Wine prefix using
/// tier-separated detection (NX Dispatch §7-8).
///
/// - Tier 1 (canonical): Windows Steam `steamapps/` directory
/// - Tier 2 (downloading): Windows Steam `steamapps/downloading/`
/// - Tier 3 (diagnostic only): `steamcmd/steamapps/`
///
/// Only Tier 1 with a complete `.installed` payload can result in `isReady = true`.
final class SteamInstallationDetector: @unchecked Sendable {
    private let fm = FileManager.default

    struct GameInstallEvidence: Sendable, Equatable {
        let manifestPresent: Bool
        let manifestAppID: String?
        let installdir: String?
        let installDirectoryResolved: Bool
        let executablePresent: Bool
        let executableName: String?
        let stateFlags: String?
        let installState: GameInstallState
        let canonicalInstallPresent: Bool
        let downloadPayloadPresent: Bool

        static var empty: GameInstallEvidence {
            GameInstallEvidence(
                manifestPresent: false,
                manifestAppID: nil,
                installdir: nil,
                installDirectoryResolved: false,
                executablePresent: false,
                executableName: nil,
                stateFlags: nil,
                installState: .notFound,
                canonicalInstallPresent: false,
                downloadPayloadPresent: false
            )
        }
    }

    /// Inspect the game installation status within a prefix.
    ///
    /// - Parameters:
    ///   - recipe: The game recipe to check.
    ///   - runtime: The active compatibility runtime.
    ///   - prefix: A validated `PrefixLayout` for the canonical prefix.
    /// - Returns: A `GameInspection` with truthful install state.
    func inspect(recipe: GameRecipe, runtime: any CompatibilityRuntime, prefix: PrefixLayout) async -> GameInspection {
        let evidence = await gatherEvidence(recipe: recipe, prefix: prefix)
        return buildInspection(recipe: recipe, evidence: evidence)
    }

    // MARK: - Tiered Evidence Gathering

    private func gatherEvidence(recipe: GameRecipe, prefix: PrefixLayout) async -> GameInstallEvidence {
        let manifestName = recipe.detection.manifestName

        // Phase 1: Steam presence
        let steamExe = prefix.windowsSteamCandidates.first { candidate in
            let exe = candidate.appendingPathComponent("steam.exe")
            return fm.isExecutableFile(atPath: exe.path)
        }
        guard steamExe != nil else {
            return GameInstallEvidence.empty
        }

        // Phase 2: Tier 1 — canonical Steam library
        let tier1Result = inspectCanonicalSteamLibrary(steamRoots: prefix.windowsSteamCandidates, manifestName: manifestName, recipe: recipe)
        if case .installed = tier1Result.installState {
            return tier1Result
        }

        // Phase 3: Tier 2 — canonical downloading area (not Ready)
        let tier2Result = inspectCanonicalDownloading(steamRoots: prefix.windowsSteamCandidates, manifestName: manifestName, recipe: recipe)
        if tier2Result.downloadPayloadPresent {
            return tier2Result
        }

        // Phase 4: Tier 3 — SteamCMD diagnostic only
        let tier3Result = inspectSteamCMD(prefix: prefix, manifestName: manifestName, recipe: recipe)

        // If Tier 1 manifest exists but install is incomplete → inconsistent
        if tier1Result.manifestPresent && !tier1Result.installDirectoryResolved {
            return GameInstallEvidence(
                manifestPresent: true,
                manifestAppID: tier1Result.manifestAppID,
                installdir: tier1Result.installdir,
                installDirectoryResolved: false,
                executablePresent: false,
                executableName: nil,
                stateFlags: tier1Result.stateFlags,
                installState: .inconsistent,
                canonicalInstallPresent: false,
                downloadPayloadPresent: tier2Result.downloadPayloadPresent
            )
        }

        // Return the most advanced evidence found
        if tier3Result.manifestPresent || tier3Result.downloadPayloadPresent {
            return tier3Result
        }

        return tier1Result.manifestPresent ? tier1Result : .empty
    }

    // MARK: - Tier 1: Canonical Steam Library

    private func inspectCanonicalSteamLibrary(steamRoots: [URL], manifestName: String, recipe: GameRecipe) -> GameInstallEvidence {
        for steamRoot in steamRoots {
            let steamapps = steamRoot.appendingPathComponent("steamapps")
            let manifestURL = steamapps.appendingPathComponent(manifestName)

            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            // Read manifest
            guard let content = try? String(contentsOf: manifestURL, encoding: .utf8),
                  let installdir = extractInstallDir(from: content) else {
                return GameInstallEvidence(
                    manifestPresent: true, manifestAppID: nil, installdir: nil,
                    installDirectoryResolved: false, executablePresent: false,
                    executableName: nil, stateFlags: nil,
                    installState: .manifestOnly,
                    canonicalInstallPresent: false, downloadPayloadPresent: false
                )
            }

            let appID = extractAppID(from: content) ?? ""
            let stateFlags = extractStateFlags(from: content)
            let commonDir = steamapps.appendingPathComponent("common").appendingPathComponent(installdir)

            // Check for complete installation
            var isDir: ObjCBool = false
            let dirExists = fm.fileExists(atPath: commonDir.path, isDirectory: &isDir) && isDir.boolValue
            let exeCandidates = recipe.detection.executableCandidates
            let exeFound = exeCandidates.first { fm.fileExists(atPath: commonDir.appendingPathComponent($0).path) }

            if dirExists, let exeName = exeFound {
                let hasUnityPlayer = fm.fileExists(atPath: commonDir.appendingPathComponent("UnityPlayer.dll").path)
                let hasCloverData = fm.fileExists(atPath: commonDir.appendingPathComponent("CloverPit_Data").path)
                let exeNonEmpty = ((try? commonDir.appendingPathComponent(exeName).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0

                if hasUnityPlayer && hasCloverData && exeNonEmpty {
                    return GameInstallEvidence(
                        manifestPresent: true,
                        manifestAppID: appID,
                        installdir: installdir,
                        installDirectoryResolved: true,
                        executablePresent: true,
                        executableName: exeName,
                        stateFlags: stateFlags,
                        installState: .installed,
                        canonicalInstallPresent: true,
                        downloadPayloadPresent: false
                    )
                }

                // Files present but incomplete → inconsistent
                return GameInstallEvidence(
                    manifestPresent: true,
                    manifestAppID: appID,
                    installdir: installdir,
                    installDirectoryResolved: true,
                    executablePresent: exeFound != nil,
                    executableName: exeName,
                    stateFlags: stateFlags,
                    installState: .inconsistent,
                    canonicalInstallPresent: false,
                    downloadPayloadPresent: false
                )
            }

            // Manifest exists but no install dir → manifestOnly
            return GameInstallEvidence(
                manifestPresent: true,
                manifestAppID: appID,
                installdir: installdir,
                installDirectoryResolved: false,
                executablePresent: false,
                executableName: nil,
                stateFlags: stateFlags,
                installState: .manifestOnly,
                canonicalInstallPresent: false,
                downloadPayloadPresent: false
            )
        }

        return .empty
    }

    // MARK: - Tier 2: Downloading Area (not Ready)

    private func inspectCanonicalDownloading(steamRoots: [URL], manifestName: String, recipe: GameRecipe) -> GameInstallEvidence {
        for steamRoot in steamRoots {
            let downloadingDir = steamRoot
                .appendingPathComponent("steamapps")
                .appendingPathComponent("downloading")
                .appendingPathComponent(recipe.store.appId)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: downloadingDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let hasExe = recipe.detection.executableCandidates.first { candidate in
                fm.fileExists(atPath: downloadingDir.appendingPathComponent(candidate).path)
            }

            return GameInstallEvidence(
                manifestPresent: false,
                manifestAppID: recipe.store.appId,
                installdir: nil,
                installDirectoryResolved: false,
                executablePresent: hasExe != nil,
                executableName: hasExe,
                stateFlags: nil,
                installState: .downloading,
                canonicalInstallPresent: false,
                downloadPayloadPresent: true
            )
        }

        return .empty
    }

    // MARK: - Tier 3: SteamCMD (diagnostic only)

    private func inspectSteamCMD(prefix: PrefixLayout, manifestName: String, recipe: GameRecipe) -> GameInstallEvidence {
        let steamcmdSteamapps = prefix.driveC
            .appendingPathComponent("steamcmd")
            .appendingPathComponent("steamapps")

        let manifestURL = steamcmdSteamapps.appendingPathComponent(manifestName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            return .empty
        }

        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8),
              let installdir = extractInstallDir(from: content) else {
            return GameInstallEvidence(
                manifestPresent: true, manifestAppID: nil, installdir: nil,
                installDirectoryResolved: false, executablePresent: false,
                executableName: nil, stateFlags: nil,
                installState: .staged,
                canonicalInstallPresent: false, downloadPayloadPresent: false
            )
        }

        let appID = extractAppID(from: content) ?? ""
        let stateFlags = extractStateFlags(from: content)

        // Check downloading/<appid>/
        let downloadingDir = steamcmdSteamapps
            .appendingPathComponent("downloading")
            .appendingPathComponent(recipe.store.appId)
        var isDir: ObjCBool = false
        let hasDownloading = fm.fileExists(atPath: downloadingDir.path, isDirectory: &isDir) && isDir.boolValue
        let exeInDownloading: String? = hasDownloading ? recipe.detection.executableCandidates.first { candidate in
            fm.fileExists(atPath: downloadingDir.appendingPathComponent(candidate).path)
        } : nil

        // Check common/<installdir>/
        let commonDir = steamcmdSteamapps.appendingPathComponent("common").appendingPathComponent(installdir)
        let hasCommon = fm.fileExists(atPath: commonDir.path, isDirectory: &isDir) && isDir.boolValue
        let exeInCommon: String? = hasCommon ? recipe.detection.executableCandidates.first { candidate in
            fm.fileExists(atPath: commonDir.appendingPathComponent(candidate).path)
        } : nil

        let installDirResolved = hasCommon || hasDownloading
        let executablePresent = exeInCommon != nil || exeInDownloading != nil

        return GameInstallEvidence(
            manifestPresent: true,
            manifestAppID: appID,
            installdir: installdir,
            installDirectoryResolved: installDirResolved,
            executablePresent: executablePresent,
            executableName: exeInCommon ?? exeInDownloading,
            stateFlags: stateFlags,
            installState: .staged,
            canonicalInstallPresent: false,
            downloadPayloadPresent: exeInDownloading != nil
        )
    }

    // MARK: - Build Inspection

    private func buildInspection(recipe: GameRecipe, evidence: GameInstallEvidence) -> GameInspection {
        // Tier 1 + .downloading must never be Ready (NX Dispatch §7)
        let isReady: Bool
        if evidence.installState == .installed {
            isReady = true
        } else {
            isReady = false
        }

        return GameInspection(
            recipeID: recipe.id,
            steamPresent: evidence.manifestPresent || evidence.downloadPayloadPresent,
            isWindowsSteam: true,
            manifestPresent: evidence.manifestPresent,
            manifestAppID: evidence.manifestAppID,
            installdir: evidence.installdir,
            installDirectoryResolved: evidence.installDirectoryResolved,
            executablePresent: evidence.executablePresent,
            executableName: evidence.executableName,
            isReady: isReady,
            stateFlags: evidence.stateFlags,
            installState: evidence.installState,
            canonicalInstallPresent: evidence.canonicalInstallPresent,
            downloadPayloadPresent: evidence.downloadPayloadPresent
        )
    }

    // MARK: - Manifest Parsing

    private func extractInstallDir(from manifest: String) -> String? {
        let patterns = [
            #"\"installdir\"\s+\"([^\"]+)\""#,
            #"\"installDir\"\s+\"([^\"]+)\""#,
            #"\"InstallDir\"\s+\"([^\"]+)\""#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)) {
                let range = match.range(at: 1)
                if let swiftRange = Range(range, in: manifest) {
                    return String(manifest[swiftRange])
                }
            }
        }
        return nil
    }

    private func extractAppID(from manifest: String) -> String? {
        let pattern = #"\"appid\"\s+\"(\d+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)) else {
            return nil
        }
        if let swiftRange = Range(match.range(at: 1), in: manifest) {
            return String(manifest[swiftRange])
        }
        return nil
    }

    private func extractStateFlags(from manifest: String) -> String? {
        let pattern = #"\"StateFlags\"\s+\"(\d+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)) else {
            return nil
        }
        if let swiftRange = Range(match.range(at: 1), in: manifest) {
            return String(manifest[swiftRange])
        }
        return nil
    }
}
