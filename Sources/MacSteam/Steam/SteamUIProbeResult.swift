// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Observable result of a Steam UI probe (§8, §9).
///
/// Records whether the Steam window appeared and whether CEF web content
/// rendered.  Used to compare `.automatic` and `.cefSoftwareRendering`
/// profiles on the same hardware.
///
/// - Note: Window titles, PIDs, and absolute paths are never stored.
struct SteamUIProbeResult: Sendable, Equatable {
    /// Which profile was active during this probe.
    let profile: SteamUIRenderProfile

    /// Whether a native window frame was created by Wine.
    let nativeWindowCreated: Bool

    /// Whether CEF web content was rendered (non-black).
    let contentRendered: Bool

    /// Whether mouse/keyboard input reached the Steam window.
    let inputWorks: Bool

    /// Whether the UI remained stable for 30+ seconds without crash.
    let stable30Seconds: Bool

    /// Free-form notes (booleans and short labels only, no paths).
    let notes: [String]
}

extension SteamUIProbeResult {
    /// A human-readable classification derived from the probe result.
    var classification: String {
        guard nativeWindowCreated else {
            return "no_window"
        }
        guard contentRendered else {
            return "black_screen"
        }
        guard inputWorks else {
            return "no_input"
        }
        guard stable30Seconds else {
            return "unstable"
        }
        return "healthy"
    }
}
