// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The result of a steam installer file selection and verification flow.
enum SteamInstallationResult {
    case fileSelected(url: URL)
    case verificationFailed(reason: String)
    case installationSubmitted
}

/// Coordinates user file selection, verification, and recording of Steam installer files.
struct SteamInstallerCoordinator {
    /// Verify that the given URL points to a plausible SteamSetup.exe installer.
    /// Checks the file extension and size constraints.
    /// - Parameter url: The file URL to verify.
    /// - Returns: `true` if the file appears to be a valid Steam installer.
    func verifyInstaller(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "exe" else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return false }
        // SteamSetup.exe is typically 1-2 MB
        return size > 100_000 && size < 10_000_000
    }

    /// Record the installation of a Steam installer file for audit/receipt purposes.
    /// - Parameters:
    ///   - url: The installer file URL that was used.
    ///   - prefixURL: The prefix URL where Steam was installed.
    /// - Returns: The SHA-256 hash of the installer file, or `nil` if hashing failed.
    func recordInstallation(url: URL, prefixURL: URL) -> String? {
        let sha = try? ArtifactVerifier.sha256(url: url)
        return sha
    }
}
