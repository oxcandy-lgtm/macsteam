// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The purpose of a game or wine session, used to determine lifecycle behaviour.
///
/// - ``steamInstaller``: SteamSetup.exe installation process.
///   ProcessSupervisor owns the installer and waits for exit.
/// - ``steamSetup``: Session is subordinate to the MacsTeam app lifecycle.
///   Terminates on back/next/app-exit. Not recovered on restart.
/// - ``game``: Standalone game session. Persists after app exit.
///   Recovered on restart via receipt.
enum SessionPurpose: String, Codable, Sendable, Equatable {
    /// SteamSetup.exe installation — owned by ProcessSupervisor.
    case steamInstaller
    /// Steam setup / Steam client session — tied to MacsTeam lifecycle.
    case steamSetup
    /// Regular game session — persists beyond app lifecycle.
    case game
}
