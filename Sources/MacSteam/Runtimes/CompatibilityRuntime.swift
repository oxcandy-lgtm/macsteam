// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Abstract interface for a compatibility runtime (CrossOver, Wine, Whisky, etc.).
///
/// Every runtime adapter must implement inspection, game detection,
/// store opening, and game launching.
///
/// The UI and ``GameManager`` never call runtime-specific code directly;
/// all interactions go through this protocol.
protocol CompatibilityRuntime: Sendable {
    /// Unique identifier for this runtime type (e.g. "crossover", "wine").
    var id: String { get }

    /// Perform self-inspection and return capabilities.
    func inspect() async -> RuntimeInspection

    /// Check whether a specific game is installed and ready.
    func inspectGame(_ recipe: GameRecipe) async -> GameInspection

    /// Open the game's store (e.g., launch Steam to the game page).
    func openStore(for recipe: GameRecipe) async throws

    /// Launch the game via this runtime.
    func launchGame(_ recipe: GameRecipe) async throws
}
