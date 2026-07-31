// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// CrossOver runtime adapter.
///
/// This implementation inspects a CrossOver.app bundle by verifying
/// its bundle identifier and the presence of key executables. Bottle
/// discovery searches user‑configurable and standard locations — never
/// the app‑bundle‑internal bottle directory.
///
/// All game/Steam launch is done through the CrossOver‑bundled `wine`
/// CLI (`--bottle` / `--cx-app`), never by executing a Windows binary
/// directly.
///
/// CrossOver itself is never copied or bundled. MacSteam only detects
/// and launches an existing installation.
final class CrossOverRuntime: CompatibilityRuntime, @unchecked Sendable {
    let id = "crossover"
    let bundleURL: URL

    private let processRunner: ProcessRunner
    private let fm = FileManager.default

    init(bundleURL: URL, processRunner: ProcessRunner = ProcessRunner()) {
        self.bundleURL = bundleURL
        self.processRunner = processRunner
    }

    // MARK: - CompatibilityRuntime

    func inspect() async -> RuntimeInspection {
        let bundleID = Bundle(url: bundleURL)?.bundleIdentifier ?? ""

        guard bundleID == "com.codeweavers.CrossOver" else {
            return RuntimeInspection(
                id: id,
                displayName: "CrossOver",
                version: nil,
                bundleURL: bundleURL,
                isValid: false,
                failure: .bundleNotValid
            )
        }

        // Check that the main GUI executable exists (basic integrity)
        let mainExe = bundleURL
            .appendingPathComponent("Contents/MacOS/CrossOver")

        guard fm.isExecutableFile(atPath: mainExe.path) else {
            return RuntimeInspection(
                id: id,
                displayName: "CrossOver",
                version: nil,
                bundleURL: bundleURL,
                isValid: false,
                failure: .executableMissing
            )
        }

        // Check that the wine CLI tool exists (required for launching).
        // wine is a macOS binary — isExecutableFile is appropriate here.
        guard wineExecutable != nil else {
            return RuntimeInspection(
                id: id,
                displayName: "CrossOver",
                version: nil,
                bundleURL: bundleURL,
                isValid: false,
                failure: .executableMissing
            )
        }

        let version = Bundle(url: bundleURL)?.infoDictionary?["CFBundleShortVersionString"] as? String

        return RuntimeInspection(
            id: id,
            displayName: "CrossOver",
            version: version,
            bundleURL: bundleURL,
            isValid: true,
            failure: nil
        )
    }

    func inspectGame(_ recipe: GameRecipe) async -> GameInspection {
        guard let (_, steamURL) = findSteamBottle() else {
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

        // Steam root is the parent directory of steam.exe
        let steamRoot = steamURL.deletingLastPathComponent()

        // Check manifest
        let manifestPath = steamRoot
            .appendingPathComponent("steamapps")
            .appendingPathComponent(recipe.detection.manifestName)
        let manifestPresent = fm.fileExists(atPath: manifestPath.path)

        // Resolve install directory from manifest
        let installDirectoryResolved: Bool
        let executablePresent: Bool

        if manifestPresent,
           let manifestContent = try? String(contentsOf: manifestPath, encoding: .utf8),
           let installDir = extractInstallDir(from: manifestContent) {

            let gameDir = steamRoot
                .appendingPathComponent("steamapps/common")
                .appendingPathComponent(installDir)

            installDirectoryResolved = fm.fileExists(atPath: gameDir.path)
            executablePresent = checkForGameExecutable(in: gameDir, candidates: recipe.detection.executableCandidates)
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

    func openStore(for recipe: GameRecipe) async throws {
        let plan = try makeStorePlan(for: recipe)
        try await performDetached(plan)
    }

    func launchGame(_ recipe: GameRecipe) async throws {
        let plan = try makeLaunchPlan(for: recipe)
        try await performDetached(plan)
    }

    // MARK: - Launch plan

    /// Build a launch plan for the game using the wine CLI.
    func makeLaunchPlan(for recipe: GameRecipe) throws -> LaunchPlan {
        guard let wine = wineExecutable else {
            throw LauncherFailure.processExecutableInvalid
        }
        let bottle = try resolveSteamBottleName()

        return LaunchPlan(
            runtimeExecutable: wine,
            arguments: [
                "--bottle", bottle,
                "--cx-app", "steam.exe"
            ] + recipe.launch.arguments,
            mode: .detached
        )
    }

    /// Build a launch plan to open the store page.
    func makeStorePlan(for recipe: GameRecipe) throws -> LaunchPlan {
        guard let wine = wineExecutable else {
            throw LauncherFailure.processExecutableInvalid
        }
        let bottle = try resolveSteamBottleName()

        return LaunchPlan(
            runtimeExecutable: wine,
            arguments: [
                "--bottle", bottle,
                "--cx-app", "steam.exe",
                "steam://store/\(recipe.store.appId)"
            ],
            mode: .detached
        )
    }

    // MARK: - Bottle discovery

    /// Discover all CrossOver bottles on this system.
    func discoverBottles() -> [BottleDescriptor] {
        let bottleRoots = resolveBottleRoots()
        var result: [BottleDescriptor] = []

        for root in bottleRoots {
            guard let contents = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for item in contents {
                let bottleDir = root.appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: bottleDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

                // A bottle must contain a drive_c/ directory
                let driveC = bottleDir.appendingPathComponent("drive_c")
                var isDriveDir: ObjCBool = false
                guard fm.fileExists(atPath: driveC.path, isDirectory: &isDriveDir), isDriveDir.boolValue else { continue }

                // Look for Windows Steam inside the bottle
                let steam = findSteamExe(in: bottleDir)
                result.append(BottleDescriptor(
                    name: item,
                    rootURL: bottleDir,
                    steamExecutableURL: steam
                ))
            }
        }
        return result
    }

    /// Find a bottle that contains Windows Steam.
    func findSteamBottle() -> (BottleDescriptor, steamURL: URL)? {
        for bottle in discoverBottles() {
            if let steamURL = bottle.steamExecutableURL {
                return (bottle, steamURL)
            }
        }
        return nil
    }

    // MARK: - Private

    /// Path to the CrossOver‑bundled wine CLI.
    /// wine is a macOS binary — `isExecutableFile` is correct here.
    private var wineExecutable: URL? {
        let candidate = bundleURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
        guard fm.isExecutableFile(atPath: candidate.path) else { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return candidate
    }

    /// Resolve bottle root directories in priority order.
    private func resolveBottleRoots() -> [URL] {
        var roots: [URL] = []

        // 1. User defaults (CodeWeavers configurable BottleDir)
        if let customDir = readCustomBottleDir() {
            roots.append(customDir)
        }

        // 2. User Library
        let userBottles = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        roots.append(userBottles)

        // 3. System Library
        let systemBottles = URL(fileURLWithPath: "/Library/Application Support/CrossOver/Bottles")
        if fm.fileExists(atPath: systemBottles.path) {
            roots.append(systemBottles)
        }

        return roots
    }

    /// Read custom BottleDir from CrossOver's preferences via `defaults` CLI.
    private func readCustomBottleDir() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.codeweavers.CrossOver", "BottleDir"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard var path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }

            // Handle tilde expansion and relative paths
            if path.hasPrefix("~") {
                path = path.replacingOccurrences(of: "~", with: fm.homeDirectoryForCurrentUser.path)
            }
            if !path.hasPrefix("/") {
                path = fm.homeDirectoryForCurrentUser.appendingPathComponent(path).path
            }
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    /// Find steam.exe inside a bottle by checking standard Windows paths.
    /// Does NOT require the POSIX executable bit — Windows .exe files are
    /// data files on macOS.
    private func findSteamExe(in bottleDir: URL) -> URL? {
        let candidates = [
            bottleDir.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
            bottleDir.appendingPathComponent("drive_c/Program Files/Steam/steam.exe")
        ]
        for candidate in candidates {
            if isRegularFile(candidate, boundedBy: bottleDir) {
                return candidate
            }
        }
        return nil
    }

    /// Resolve the bottle name that contains Steam, or throw.
    private func resolveSteamBottleName() throws -> String {
        guard let (bottle, _) = findSteamBottle() else {
            throw LauncherFailure.processStartFailed(underlying: "No Windows Steam bottle found")
        }
        return bottle.name
    }

    /// Launch a plan in detached mode.  Errors from process spawning
    /// propagate directly to the caller (no silent `Task` swallow).
    private func performDetached(_ plan: LaunchPlan) async throws {
        guard plan.mode == .detached else {
            throw LauncherFailure.processStartFailed(
                underlying: "Expected detached launch mode"
            )
        }
        _ = try await processRunner.run(
            executable: plan.runtimeExecutable,
            arguments: plan.arguments,
            mode: .detached
        )
    }

    // MARK: - File helpers

    /// Check whether `url` is a regular file (not a directory, not a
    /// symlink escaping the bounded root) with a `.exe` extension.
    ///
    /// Does NOT require the POSIX executable bit — Windows .exe files
    /// are data files when copied to macOS and should not be rejected
    /// for lacking the executable permission.
    private func isRegularFile(_ url: URL, boundedBy root: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return false }

        guard url.pathExtension.lowercased() == "exe" else { return false }

        // Resolve symlinks and verify the resolved path stays inside the bottle
        let resolved: URL
        if let linkDest = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            resolved = URL(fileURLWithPath: linkDest, relativeTo: url.deletingLastPathComponent()).standardized
        } else {
            resolved = url.standardized
        }

        let rootStd = root.standardized.path
        return resolved.path.hasPrefix(rootStd)
    }

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
    /// Uses `isRegularFile` so POSIX executable bit is not required.
    private func checkForGameExecutable(in directory: URL, candidates: [String]?) -> Bool {
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        if let candidates, !candidates.isEmpty {
            // At least one candidate must be present AND be a regular file
            return candidates.contains { candidate in
                isRegularFile(directory.appendingPathComponent(candidate), boundedBy: directory)
            }
        }
        // Fallback: any .exe file
        return contents.contains { $0.hasSuffix(".exe") }
    }
}
