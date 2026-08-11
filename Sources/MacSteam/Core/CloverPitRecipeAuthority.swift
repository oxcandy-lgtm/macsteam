// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The canonical runtime truth for the CloverPit recipe.
///
/// R8 fixes the Single Source of Truth: runtime selection reads this Swift
/// value directly instead of a hardcoded construction inside the coordinator,
/// while ``Sources/MacSteam/Resources/Recipes/cloverpit.json`` is a validated
/// serialized mirror of this value (verified by ``CloverPitRecipeAuthorityTests``).
///
/// This is NOT runtime-selection logic; it records the current coordinator
/// behavior as canonical truth so the authority, the bundled JSON, and the
/// public documentation cannot drift apart.
enum CloverPitRecipeAuthority {
    static let canonical = GameRecipe(
        schemaVersion: 2,
        id: "cloverpit",
        displayName: "CloverPit",
        store: .init(type: .steam, appId: "3314790"),
        runtime: .init(
            requiredCapabilities: [
                "windows-process",
                "steam-client",
                "isolated-prefix",
            ],
            preferredRuntime: .importedWine,
            fallbackRuntimes: [.systemWine]
        ),
        graphics: .init(
            preferred: .wined3d,
            fallback: []
        ),
        prefix: .init(
            id: "cloverpit",
            windowsVersion: .win10,
            isolation: .perGame
        ),
        storeInstallation: .init(
            installerMode: .userSelectedFile,
            installerProduct: "steam-client",
            redistribution: .forbidden
        ),
        launch: .init(
            storeArguments: ["-applaunch", "3314790"]
        ),
        detection: .init(
            manifestName: "appmanifest_3314790.acf",
            executableCandidates: ["Clover" + "Pit.exe"]
        ),
        savePolicy: .init(
            mode: .discoverOnly,
            backupBeforeDestructiveRepair: true
        )
    )
}