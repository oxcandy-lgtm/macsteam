// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// CrossOver runtime adapter.
///
/// This implementation inspects a CrossOver.app bundle by verifying
/// its bundle identifier and the presence of key executables. It does
/// **not** hardcode internal CrossOver directory paths beyond what is
/// necessary for bundle validation.
///
/// CrossOver itself is never copied or bundled. MacSteam only detects
/// and launches an existing installation.
final class CrossOverRuntime: CompatibilityRuntime, @unchecked Sendable {
    let id = "crossover"
    let bundleURL: URL

    private let processRunner: ProcessRunner

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

        // Check that the main executable exists
        let mainExe = bundleURL
            .appendingPathComponent("Contents/MacOS/CrossOver")

        guard FileManager.default.isExecutableFile(atPath: mainExe.path) else {
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
        // Steam detection within CrossOver's bottle structure
        let steamDetector = SteamDetector()

        let steamResult = steamDetector.detectWindowsSteam(in: self)

        guard case .windowsSteamFound(let steamURL) = steamResult else {
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

        return steamDetector.inspectGame(recipe, windowsSteamURL: steamURL)
    }

    func openStore(for recipe: GameRecipe) async throws {
        // Launch Windows Steam via CrossOver to the game's store page
        let steamURL = try await resolveWindowsSteamURL()
        let process = Process()
        process.executableURL = steamURL
        process.arguments = [
            "steam://store/\(recipe.store.appId)"
        ]
        try process.run()
        process.waitUntilExit()
    }

    func launchGame(_ recipe: GameRecipe) async throws {
        let steamURL = try await resolveWindowsSteamURL()
        let result = try await processRunner.run(
            executable: steamURL,
            arguments: recipe.launch.arguments
        )

        if result.exitCode != 0 {
            throw LauncherFailure.processExitedWithError(code: result.exitCode)
        }
    }

    // MARK: - Private

    private func resolveWindowsSteamURL() async throws -> URL {
        // Typical location of Windows steam.exe inside a CrossOver bottle
        // This is an approximation – actual path may vary by bottle configuration.
        let candidates = [
            bundleURL
                .appendingPathComponent("Contents/SharedSupport/CrossOver")
                .appendingPathComponent("Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe"),
            bundleURL
                .appendingPathComponent("Contents/SharedSupport/CrossOver")
                .appendingPathComponent("Bottles/Steam/drive_c/Program Files/Steam/steam.exe")
        ]

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw LauncherFailure.processExecutableInvalid
    }
}
