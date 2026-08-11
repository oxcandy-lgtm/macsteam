// SPDX-License-Identifier: GPL-3.0-or-later

/// Represents the pages/screens in the Steam installer flow.
public enum InstallerPage: String, Codable, CaseIterable, Sendable {
    case runtime
    case environment
    case steamInstaller
    case steamClient
    case cloverPit
    case diagnostics
}
