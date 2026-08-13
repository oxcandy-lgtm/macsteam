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
        /// CLOVERPIT-WINDOWS-INSTALL1 §1: evidence found in a non-canonical
        /// location (SteamCMD staging area). Diagnosed only — never the install
        /// authority and never readiness.
        let noncanonicalPayloadPresent: Bool
        /// CLOVERPIT-WINDOWS-INSTALL1 §7: byte progress read from the canonical
        /// manifest (`BytesDownloaded` / `BytesToDownload`). Nil when the
        /// manifest does not report a value.
        let bytesDownloaded: Int64?
        let bytesTotal: Int64?

        static var empty: GameInstallEvidence {
            GameInstallEvidence(
                manifestPresent: false,
                manifestAppID: nil,
                installdir: nil,
                installDirectoryResolved: false,
                executablePresent: false,
                executableName: nil,
                stateFlags: nil,
                installState: .notInstalled,
                canonicalInstallPresent: false,
                downloadPayloadPresent: false,
                noncanonicalPayloadPresent: false,
                bytesDownloaded: nil,
                bytesTotal: nil
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

        // Phase 4: Tier 1 manifest exists but install is incomplete → the
        // canonical Windows Steam library has accepted the install but not yet
        // delivered a resolvable install directory (CLOVERPIT-WINDOWS-INSTALL1 §1).
        if tier1Result.manifestPresent && !tier1Result.installDirectoryResolved {
            return GameInstallEvidence(
                manifestPresent: true,
                manifestAppID: tier1Result.manifestAppID,
                installdir: tier1Result.installdir,
                installDirectoryResolved: false,
                executablePresent: false,
                executableName: nil,
                stateFlags: tier1Result.stateFlags,
                installState: .installRequested,
                canonicalInstallPresent: false,
                downloadPayloadPresent: tier2Result.downloadPayloadPresent,
                noncanonicalPayloadPresent: false,
                bytesDownloaded: tier1Result.bytesDownloaded,
                bytesTotal: tier1Result.bytesTotal
            )
        }

        // Phase 5: Tier 3 — SteamCMD diagnostic ONLY. A leftover SteamCMD
        // staging area is a non-canonical payload: it must never be reported as
        // staged/installing/ready nor count toward canonical install truth.
        let tier3Result = inspectSteamCMD(prefix: prefix, manifestName: manifestName, recipe: recipe)
        if tier3Result.noncanonicalPayloadPresent {
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
                    installState: .blocked,
                    canonicalInstallPresent: false, downloadPayloadPresent: false,
                    noncanonicalPayloadPresent: false,
                    bytesDownloaded: nil, bytesTotal: nil
                )
            }

            let appID = extractAppID(from: content) ?? ""
            let stateFlags = extractStateFlags(from: content)
            let bytesDownloaded = extractBytesDownloaded(from: content)
            let bytesTotal = extractBytesTotal(from: content)
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
                        downloadPayloadPresent: false,
                        noncanonicalPayloadPresent: false,
                        bytesDownloaded: bytesDownloaded,
                        bytesTotal: bytesTotal
                    )
                }

                // Files present but incomplete → installing (canonical location,
                // not yet complete; blocked only if nothing can advance).
                return GameInstallEvidence(
                    manifestPresent: true,
                    manifestAppID: appID,
                    installdir: installdir,
                    installDirectoryResolved: true,
                    executablePresent: exeFound != nil,
                    executableName: exeName,
                    stateFlags: stateFlags,
                    installState: .installing,
                    canonicalInstallPresent: false,
                    downloadPayloadPresent: false,
                    noncanonicalPayloadPresent: false,
                    bytesDownloaded: bytesDownloaded,
                    bytesTotal: bytesTotal
                )
            }

            // Manifest exists but no install dir → install accepted, not delivered.
            return GameInstallEvidence(
                manifestPresent: true,
                manifestAppID: appID,
                installdir: installdir,
                installDirectoryResolved: false,
                executablePresent: false,
                executableName: nil,
                stateFlags: stateFlags,
                installState: .installRequested,
                canonicalInstallPresent: false,
                downloadPayloadPresent: false,
                noncanonicalPayloadPresent: false,
                bytesDownloaded: bytesDownloaded,
                bytesTotal: bytesTotal
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
                downloadPayloadPresent: true,
                noncanonicalPayloadPresent: false,
                bytesDownloaded: nil,
                bytesTotal: nil
            )
        }

        return .empty
    }

    // MARK: - Tier 3: SteamCMD (diagnostic ONLY)

    /// CLOVERPIT-WINDOWS-INSTALL1 §1/§12: a leftover SteamCMD staging area is a
    /// non-canonical payload. It is diagnosed (flag surfaced to the terminal)
    /// but NEVER projected as a canonical manifest, install directory,
    /// executable, download payload, or readiness. Old staging/download hints
    /// must never be interpreted as CloverPit installed/ready.
    private func inspectSteamCMD(prefix: PrefixLayout, manifestName: String, recipe: GameRecipe) -> GameInstallEvidence {
        let steamcmdSteamapps = prefix.driveC
            .appendingPathComponent("steamcmd")
            .appendingPathComponent("steamapps")

        let manifestURL = steamcmdSteamapps.appendingPathComponent(manifestName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            return .empty
        }

        // Diagnose the mere existence of the leftover staging area.
        return GameInstallEvidence(
            manifestPresent: false,
            manifestAppID: nil,
            installdir: nil,
            installDirectoryResolved: false,
            executablePresent: false,
            executableName: nil,
            stateFlags: nil,
            installState: .notInstalled,
            canonicalInstallPresent: false,
            downloadPayloadPresent: false,
            noncanonicalPayloadPresent: true,
            bytesDownloaded: nil,
            bytesTotal: nil
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
            steamPresent: evidence.manifestPresent || evidence.downloadPayloadPresent || evidence.noncanonicalPayloadPresent,
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
            downloadPayloadPresent: evidence.downloadPayloadPresent,
            noncanonicalPayloadPresent: evidence.noncanonicalPayloadPresent,
            bytesDownloaded: evidence.bytesDownloaded,
            bytesTotal: evidence.bytesTotal
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

    /// CLOVERPIT-WINDOWS-INSTALL1 §7: read `BytesDownloaded` (or
    /// `BytesToDownload`-style keys) from the manifest.
    private func extractByteValue(from manifest: String, key: String) -> Int64? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #""\#(escaped)"\s+"(\d+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)) else {
            return nil
        }
        if let swiftRange = Range(match.range(at: 1), in: manifest) {
            return Int64(manifest[swiftRange])
        }
        return nil
    }

    private func extractBytesDownloaded(from manifest: String) -> Int64? {
        if let value = extractByteValue(from: manifest, key: "BytesDownloaded") { return value }
        return extractByteValue(from: manifest, key: "BytesToDownload")
    }

    private func extractBytesTotal(from manifest: String) -> Int64? {
        if let value = extractByteValue(from: manifest, key: "BytesToDownload") { return value }
        return extractByteValue(from: manifest, key: "BytesToStage")
    }
}
