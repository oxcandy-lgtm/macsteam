// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// View for the Windows Steam installer flow.
///
/// NX Dispatch U1R11 — all actions wired through ``UltimateSetupCoordinator``.
/// No local fake timers.  Handles the full Steam lifecycle:
///  1. Download Steam installer (open browser)
///  2. Select & verify SteamSetup.exe
///  3. Install via coordinator
///  4. Re-check / detect installation
///
/// Back → `prefixReady`, Next → `cloverPitNotInstalled`.
struct SteamSetupView: View {
    let coordinator: UltimateSetupCoordinator
    @State private var installerURL: URL? = nil
    @State private var fileSize: UInt64 = 0
    @State private var isVerified = false
    @State private var verificationMessage: String = ""
    @State private var isWorking = false

    private let steamDownloadURL = "https://store.steampowered.com/about/"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if coordinator.state == .steamReady {
                steamReadyContent
            } else {
                stepsContent
            }

            Spacer()
            navigationButtons
        }
        .padding(24)
        .frame(width: 500)
        .disabled(isWorking)
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
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusSubtitle: String {
        switch coordinator.state {
        case .steamReady:
            return "Windows Steam is installed and ready"
        case .steamInstallationPending:
            return "Installing Steam inside the prefix"
        case .steamInstallerVerified:
            return "Installer selected — ready to install"
        default:
            return "Install Steam inside the CloverPit environment"
        }
    }

    // MARK: - Steam Ready

    private var steamReadyContent: some View {
        VStack(spacing: 12) {
            Label("Windows Steam ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            Text("Steam is installed in the prefix.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let insp = coordinator.steamInspection, insp.steamInstalled {
                Text("Steam executable detected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Open Windows Steam") {
                    Task { await coordinator.launchWindowsSteam() }
                }
                .buttonStyle(.borderedProminent)

                Button("Re-check") {
                    isWorking = true
                    Task {
                        await coordinator.recheckSteam()
                        isWorking = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: - Steps (not yet installed)

    private var stepsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepView(
                number: 1,
                title: "Download Steam Installer",
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
                detail: step3Detail,
                state: step3State,
                action: {
                    isWorking = true
                    Task {
                        await coordinator.installSteam()
                        isWorking = false
                    }
                }
            )
            .disabled(!isVerified || coordinator.state == .steamInstallationPending)

            stepView(
                number: 4,
                title: "Detect Windows Steam",
                detail: step4Detail,
                state: step4State,
                action: {
                    isWorking = true
                    Task {
                        await coordinator.recheckSteam()
                        isWorking = false
                    }
                }
            )
            .disabled(coordinator.state != .steamInstallationPending)

            // Error / crash info
            if let error = coordinator.error {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Retry") {
                        coordinator.error = nil
                        isWorking = true
                        Task {
                            await coordinator.installSteam()
                            isWorking = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Stop Steam") {
                        Task { await coordinator.stopSession() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Back") {
                        Task {
                            try? await coordinator.stopSteamSetupSessionIfNeeded()
                            coordinator.state = .prefixReady
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Step state helpers

    private var step3State: StepUIState {
        switch coordinator.state {
        case .steamInstallationPending:
            return .working
        case .steamReady:
            return .completed
        case .steamInstallerVerified:
            return .ready
        default:
            return isVerified ? .ready : .pending
        }
    }

    private var step3Detail: String {
        switch coordinator.state {
        case .steamInstallationPending:
            return "Installing… follow the Steam Setup window"
        case .steamReady:
            return "Steam installed successfully"
        default:
            return "Run SteamSetup.exe inside the prefix"
        }
    }

    private var step4State: StepUIState {
        switch coordinator.state {
        case .steamReady:
            return .completed
        default:
            return coordinator.state == .steamInstallationPending ? .ready : .pending
        }
    }

    private var step4Detail: String {
        guard let insp = coordinator.steamInspection else {
            return "Check whether Steam was installed correctly"
        }
        return insp.steamInstalled ? "Windows Steam detected" : "Steam not found yet"
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if coordinator.state != .steamReady {
                Button("Back") {
                    Task {
                        try? await coordinator.stopSteamSetupSessionIfNeeded()
                        coordinator.state = .prefixReady
                    }
                }
                .controlSize(.small)
                .disabled(isWorking)
            }

            Spacer()

            if coordinator.state == .steamReady {
                Button("Next: Check CloverPit →") {
                    Task {
                        try? await coordinator.stopSteamSetupSessionIfNeeded()
                        await coordinator.recheckCloverPit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
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
        // Basic file info
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileSize = size
        }

        isWorking = true
        Task {
            await coordinator.selectSteamInstaller(url)
            isVerified = (coordinator.error == nil)
            if isVerified {
                verificationMessage = "Installer verified"
            } else {
                verificationMessage = coordinator.error?.localizedDescription ?? "Verification failed"
            }
            isWorking = false
        }
    }

    // MARK: - Helpers

    private var fileDetail: String {
        guard let url = installerURL else { return "No file selected" }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        let verifiedStr = isVerified ? "✓ Verified" : "✗ \(verificationMessage)"
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
