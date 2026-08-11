// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The state of Steam readiness for a given launch plan.
struct SteamLaunchState {
    let plan: LaunchPlan
    let steamInstalled: Bool
}

/// Coordinates the creation of launch plans for Steam games.
struct SteamLaunchCoordinator {
    /// Build a `LaunchPlan` for the Steam executable within a prefix.
    /// - Parameters:
    ///   - prefixURL: The prefix directory to check for Steam.
    ///   - recipe: The game recipe containing store arguments.
    /// - Returns: A `LaunchPlan` if Steam is installed, or `nil` otherwise.
    func makeLaunchPlan(prefixURL: URL, recipe: GameRecipe) -> LaunchPlan? {
        let steamExe = prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path) else { return nil }
        return LaunchPlan(
            runtimeExecutable: steamExe,
            arguments: recipe.launch.storeArguments,
            mode: .detached
        )
    }
}
