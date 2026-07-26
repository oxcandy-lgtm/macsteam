// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The result of inspecting a single prefix directory.
struct PrefixInspection {
    let prefixURL: URL
    let driveCExists: Bool
    let hasWinePrefix: Bool
    let hasSteam: Bool
    let isValid: Bool
}

/// Inspects a Wine prefix directory to determine its structure and contents.
struct PrefixInspector {
    private let fm = FileManager.default

    /// Inspect the prefix at the given URL.
    /// - Parameter url: The prefix directory to inspect.
    /// - Returns: A `PrefixInspection` describing the prefix's state.
    func inspect(url: URL) -> PrefixInspection {
        let driveC = url.appendingPathComponent("drive_c")
        let driveCExists = fm.fileExists(atPath: driveC.path)

        let winePrefix = url.appendingPathComponent(".wine")
        let hasWinePrefix = fm.fileExists(atPath: winePrefix.path)

        let steamExe1 = driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
        let steamExe2 = driveC.appendingPathComponent("Program Files/Steam/steam.exe")
        let hasSteam = fm.fileExists(atPath: steamExe1.path) || fm.fileExists(atPath: steamExe2.path)

        let hasUserDir = fm.fileExists(atPath: driveC.appendingPathComponent("users").path)
        let hasWindowsDir = fm.fileExists(atPath: driveC.appendingPathComponent("windows").path)

        let isValid = driveCExists && hasUserDir && hasWindowsDir

        return PrefixInspection(
            prefixURL: url,
            driveCExists: driveCExists,
            hasWinePrefix: hasWinePrefix,
            hasSteam: hasSteam,
            isValid: isValid
        )
    }
}
