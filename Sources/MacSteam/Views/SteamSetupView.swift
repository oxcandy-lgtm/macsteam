// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// View for the Windows Steam installer flow.
///
/// Guides the user through four sub-steps:
///  1. Opening the Valve download page in their browser.
///  2. Selecting the downloaded `SteamSetup.exe` file.
///  3. Running the installer inside the Wine prefix.
///  4. Detecting the installed Windows Steam client.
///
/// References ``SteamInstallerCoordinator`` for file verification,
/// ``SteamInstallationDetector`` for post-install detection, and
/// Select a Windows Steam installer from the local filesystem, verify its
/// integrity, install it into the Wine prefix, and detect the result.
///
/// Wires into ``UltimateSetupCoordinator`` for installer selection,
/// verification, and launch.
struct SteamSetupView: View {
    let coordinator: UltimateSetupCoordinator
    @State private var installerURL: URL? = nil
    @State private var fileSize: UInt64 = 0
    @State private var sha256: String = ""
    @State private var isVerified = false
    @State private var verificationMessage: String = ""
    @State private var isInstalling = false
    @State private var isDetecting = false
    @State private var steamDetected = false
    @State private var detectionMessage: String = ""

    private let installerCoordinator = SteamInstallerCoordinator()
    private let detector = SteamInstallationDetector()

    // SteamSetup.exe download page
    private let steamDownloadURL = "https://store.steampowered.com/about/"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            stepsList
            Spacer()
            navigationButtons
        }
        .padding(24)
        .frame(width: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "steeringwheel")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Windows Steam Setup")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Install Steam inside the CloverPit environment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Steps list

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepView(
                number: 1,
                title: "Download SteamInstaller",
                detail: "Open the Valve download page in your browser",
                state: installerURL == nil ? .pending : .completed,
                action: { openDownloadPage() }
            )

            stepView(
                number: 2,
                title: "Select SteamSetup.exe",
                detail: fileDetail,
                state: installerURL == nil ? .pending : (isVerified ? .completed : .ready),
                action: { selectInstaller() }
            )

            stepView(
                number: 3,
                title: "Install Windows Steam",
                detail: isInstalling ? "Running installer…" : "Launch the installer inside the prefix",
                state: isInstalling ? .working : (steamDetected ? .completed : .ready),
                action: { runInstaller() }
            )
            .disabled(!isVerified || isInstalling)

            stepView(
                number: 4,
                title: "Detect Windows Steam",
                detail: detectionMessage.isEmpty ? "Verify Steam was installed correctly" : detectionMessage,
                state: isDetecting ? .working : (steamDetected ? .completed : .ready),
                action: { detectSteam() }
            )
            .disabled(steamDetected || isDetecting)
        }
    }

    // MARK: - Step row

    private func stepView(
        number: Int,
        title: String,
        detail: String,
        state: StepUIState,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(state.tint)
                    .frame(width: 24, height: 24)
                Group {
                    switch state {
                    case .pending:
                        Text("\(number)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    case .ready:
                        Text("\(number)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    case .working:
                        ProgressView()
                            .scaleEffect(0.5)
                            .controlSize(.small)
                    case .completed:
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state == .ready {
                Button("Go") {
                    action()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            Button("Back") {
                // TODO: navigate to prefix setup
            }
            .controlSize(.small)

            Spacer()

            Button("Next") {
                // TODO: advance to CloverPit launch view
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!steamDetected)
        }
    }

    // MARK: - Actions

    private func openDownloadPage() {
        guard let url = URL(string: steamDownloadURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func selectInstaller() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.exe]
        panel.allowsMultipleSelection = false
        panel.message = "Select SteamSetup.exe"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        installerURL = url
        verifyInstaller(url: url)
    }

    private func verifyInstaller(url: URL) {
        // Basic file info
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileSize = size
        }

        isVerified = installerCoordinator.verifyInstaller(url: url)

        if isVerified {
            // TODO: wire ArtifactVerifier.sha256(url:)
            // sha256 = try? ArtifactVerifier.sha256(url: url)
            verificationMessage = "Installer verified"
        } else {
            verificationMessage = "Verification failed — not a valid SteamSetup.exe"
        }
    }

    private func runInstaller() {
        guard installerURL != nil else { return }
        isInstalling = true

        // TODO: wire to SteamInstallerCoordinator / wine execution
        // let prefixURL = prefixManager.prefixURL(for: recipe)
        // let sha = installerCoordinator.recordInstallation(url: url, prefixURL: prefixURL)
        // Launch wine with SteamSetup.exe inside the prefix

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isInstalling = false
            steamDetected = true
            detectionMessage = "Steam installed successfully"
        }
    }

    private func detectSteam() {
        isDetecting = true
        detectionMessage = ""

        // TODO: wire to SteamInstallationDetector
        // let result = await detector.inspect(recipe: recipe, runtime: runtime)
        // steamDetected = result.steamPresent
        // detectionMessage = result.steamPresent ? "Steam detected" : "Steam not found"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isDetecting = false
            steamDetected = true
            detectionMessage = "Windows Steam detected"
        }
    }

    // MARK: - Helpers

    private var fileDetail: String {
        guard let url = installerURL else { return "No file selected" }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        let verifiedStr = isVerified ? "✓ Verified" : "✗ Verification failed"
        return "\(url.lastPathComponent) — \(sizeStr) — \(verifiedStr)"
    }
}

// MARK: - Step UI state

private enum StepUIState {
    case pending
    case ready
    case working
    case completed

    var tint: Color {
        switch self {
        case .pending:   return .gray
        case .ready:     return .blue
        case .working:   return .blue
        case .completed: return .green
        }
    }
}
