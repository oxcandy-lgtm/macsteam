// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Manages user preferences and persisted state.
///
/// Stores only non‑sensitive data (runtime selection, window prefs, etc.).
final class SettingsStore: @unchecked Sendable {

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key {
        static let selectedRuntimePath = "selectedRuntimePath"
        static let firstLaunchComplete = "firstLaunchComplete"
    }

    // MARK: - Runtime path

    /// Persisted path to the user's selected runtime bundle.
    var selectedRuntimePath: String? {
        get { defaults.string(forKey: Key.selectedRuntimePath) }
        set { defaults.set(newValue, forKey: Key.selectedRuntimePath) }
    }

    /// The selected runtime URL, if any.
    var selectedRuntimeURL: URL? {
        guard let path = selectedRuntimePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - First launch

    var isFirstLaunch: Bool {
        get { !defaults.bool(forKey: Key.firstLaunchComplete) }
        set {
            if !newValue {
                defaults.set(true, forKey: Key.firstLaunchComplete)
            }
        }
    }
}
