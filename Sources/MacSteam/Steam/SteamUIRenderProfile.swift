// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Steam UI render profiles for CEF web-rendering compatibility.
///
/// NX Dispatch U1R10 §3 — each profile maps to a fixed set of launch
/// arguments that are applied **only** to the Steam client process.
/// Game launch arguments (`-applaunch`, `-popupwindow`) are never
/// interleaved with these.
///
/// - Note: Persistence is explicitly forbidden (§5).  These profiles
///   are not saved to UserDefaults or AppStorage.  They are reset to
///   `.automatic` on every app launch.
enum SteamUIRenderProfile: String, Sendable, Codable, CaseIterable {
    /// No CEF-related arguments — let Steam/CEF negotiate the renderer.
    case automatic

    /// Force software rendering in Chromium Embedded Framework.
    /// Corresponds to the `-cef-disable-gpu` Steam flag.
    case cefSoftwareRendering
}

extension SteamUIRenderProfile {
    /// Launch arguments to append to the Steam executable path.
    ///
    /// The returned array contains **only** the arguments that are
    /// specific to this profile.  They are intended to be inserted
    /// between the Steam executable path and any game-launch arguments
    /// (e.g. `-applaunch <id>`).
    var launchArguments: [String] {
        switch self {
        case .automatic:
            return []
        case .cefSoftwareRendering:
            return ["-cef-disable-gpu"]
        }
    }
}
