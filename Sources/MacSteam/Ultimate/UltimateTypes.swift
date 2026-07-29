// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Supporting types

/// Verified installer file info — no personal data stored.
struct VerifiedInstaller: Equatable, Sendable {
    let fileURL: URL
    let fileName: String
    let fileSize: Int64
    let sha256: String
}

/// Result of inspecting a Steam installation within a Wine prefix.
struct SteamInstallationInspection: Equatable, Sendable {
    let steamInstalled: Bool
    let steamExePath: String?  // relative to prefix root, redacted
    let steamVersion: String?

    static let notFound = SteamInstallationInspection(
        steamInstalled: false, steamExePath: nil, steamVersion: nil
    )
}

/// Setup errors that can occur during the Ultimate U1 flow.
enum UltimateSetupError: Error, LocalizedError, Sendable {
    case runtimeNotFound
    case runtimeInspectionFailed(String)
    case prefixCreationFailed(String)
    case installerSelectionFailed(String)
    case installerVerificationFailed(String)
    case steamInstallationFailed(String)
    case cloverPitNotDetected(String)
    case launchFailed(String)
    case ownershipRequired(String)
    case processTimeout(String)
    case processCancelled

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound: return "No compatible Wine runtime found."
        case .runtimeInspectionFailed(let msg): return "Runtime inspection failed: \(msg)"
        case .prefixCreationFailed(let msg): return "Prefix creation failed: \(msg)"
        case .installerSelectionFailed(let msg): return "Installer selection failed: \(msg)"
        case .installerVerificationFailed(let msg): return "Installer verification failed: \(msg)"
        case .steamInstallationFailed(let msg): return "Steam installation failed: \(msg)"
        case .cloverPitNotDetected(let msg): return "CloverPit not detected: \(msg)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        case .ownershipRequired(let msg): return "Ownership required: \(msg)"
        case .processTimeout(let msg): return "Process timed out: \(msg)"
        case .processCancelled: return "Process was cancelled."
        }
    }
}

/// Launch phases beyond mere spawn.
enum LaunchPhase: String, Sendable, Equatable {
    case launched     // Process.spawn succeeded
    case processObserved  // Process is running ≥2s
    case windowConfirmed  // User confirmed visible window
    case mainMenuConfirmed  // User confirmed main menu
}

/// Purpose of a session (NX Dispatch §5).
enum SessionPurpose: String, Sendable, Codable {
    case steamSetup
    case steamClient
    case game
}
