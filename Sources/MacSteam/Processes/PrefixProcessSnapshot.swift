// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A point-in-time snapshot of the Windows process state inside a Wine prefix.
struct PrefixProcessSnapshot: Sendable, Codable {
    /// Summary of running Windows processes by known category.
    let windowsProcesses: PrefixWindowsProcessSummary
    /// Whether the wineserver process is running for this prefix.
    let wineserverRunning: Bool
    /// Any non-fatal errors collected during the scan.
    let scanErrors: [String]
    /// When the snapshot was taken.
    let timestamp: Date
}

/// Categorized counts of Windows processes in a Wine prefix.
struct PrefixWindowsProcessSummary: Sendable, Codable {
    let steamSetup: Int
    let steam: Int
    let steamWebHelpers: Int
    let steamService: Int
    let crashHandler: Int
    let other: Int
    let total: Int
}
