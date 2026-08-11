// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of detecting Windows Steam inside a runtime.
enum SteamDetectionResult: Sendable, Equatable {
    /// Windows Steam found at the given URL (the steam.exe file location).
    case windowsSteamFound(URL)
    /// Only native macOS Steam was detected.
    case nativeMacSteamOnly
    /// No Steam installation of either kind was found.
    case noSteamFound
}

/// Detects Windows Steam installations inside a compatibility runtime.
final class SteamDetector: @unchecked Sendable {
    private let fm = FileManager.default

    /// Detect Windows Steam inside a given runtime using its launch plan.
    /// Falls back to known locations for each runtime type.
    func detectWindowsSteam(in runtime: any CompatibilityRuntime, recipe: GameRecipe) async -> SteamDetectionResult {
        // Try to detect via the runtime's own capability
        let inspection = runtime.inspect()

        // If this is a Wine runtime, check for Steam in expected prefix locations
        if inspection.runtimeID == "imported-wine" || inspection.runtimeID == "system-wine" || inspection.runtimeID == "managed-wine" {
            let prefixDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/\(recipe.prefix.id)")

            let steamCandidates = [
                prefixDir.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
                prefixDir.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"),
            ]

            for candidate in steamCandidates {
                if fm.fileExists(atPath: candidate.path) {
                    return .windowsSteamFound(candidate)
                }
            }

            return .noSteamFound
        }

        // For generic runtimes, return noSteamFound (will be populated after Steam installer runs)
        return .noSteamFound
    }
}
