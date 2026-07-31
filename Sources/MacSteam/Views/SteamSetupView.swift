// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers
import MacsTeamNavigationCore

/// View for the Windows Steam installer flow.
///
/// Rendered as TWO production-separated surfaces:
/// - ``mode == .installer`` (page `.steamInstaller`): download, select,
///   verify, and install `SteamSetup.exe` — installer-specific blockers.
/// - ``mode == .client`` (page `.steamClient`): verified installed-client
///   evidence, launch, re-check, client status — client-specific blockers.
///
/// All navigation goes through `coordinator.send(intent)` (canonical lane);
/// there are no local fake timers or direct state mutations.
struct SteamSetupView: View {
    let coordinator: UltimateSetupCoordinator
    let mode: SteamSetupMode
    /// The page's production presentation (footer page MUST come from here).
    let presentation: UltimatePagePresentation

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
            switch mode {
            case .installer:
                installerContent
            case .client:
                clientContent
            }
            Spacer()
            blockerBanner
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
                Text(mode == .installer ? "Steam Installer" : "Steam Client")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(mode == .installer
                    ? "Download, verify, and install SteamSetup.exe"
                    : "Detect, launch, and manage Windows Steam")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Installer surface (page .steamInstaller)

    private var installerContent: some View {
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

            installerErrorSection
        }
    }

    /// Installer-specific blocker/error handling (retry / stop / back).
    @ViewBuilder
    private var installerErrorSection: some View {
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
                    Task {
                        await coordinator.send(.stopAndClean)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Back") {
                    Task {
                        await coordinator.send(.back)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Client surface (page .steamClient)

    private var clientContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Verified installed-client evidence (from canonical prefix)
            HStack(spacing: 10) {
                Image(systemName: coordinator.steamInspection?.steamInstalled == true
                    ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(coordinator.steamInspection?.steamInstalled == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.steamInspection?.steamInstalled == true
                        ? "Windows Steam installed" : "Steam client not detected yet")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(clientEvidenceDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Client lifecycle status (installing / interrupted)
            steamInstallStatusView

            HStack(spacing: 12) {
                Button(steamButtonLabel) {
                    Task { await coordinator.launchWindowsSteam() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSteamButtonDisabled)

                Button("Re-check") {
                    isWorking = true
                    Task {
                        await coordinator.recheckSteam()
                        isWorking = false
                    }
                }
                .buttonStyle(.bordered)
            }

            // Client-specific blocker
            if case .recoveryRequired = coordinator.steamClientState {
                Label(
                    "Steam client needs recovery. Use Stop & Clean before continuing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding()
    }

    private var clientEvidenceDetail: String {
        guard let insp = coordinator.steamInspection else {
            return "Re-check after installation"
        }
        return insp.steamInstalled
            ? "Steam executable detected in canonical prefix"
            : "Steam executable not found yet"
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

    // MARK: - Navigation (canonical lane)

    @ViewBuilder
    private var blockerBanner: some View {
        if let result = coordinator.lastNavigationResult, !result.accepted, let blocker = result.blocker {
            Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
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

// MARK: - Steam client button state

private extension SteamSetupView {
    var steamButtonLabel: String {
        switch coordinator.steamClientState {
        case .runningVisible, .runningHidden: "Show Windows Steam"
        case .launching: "Launching…"
        case .stopping: "Stopping…"
        case .stopped, .stale, .recoveryRequired: "Open Windows Steam"
        }
    }

    var isSteamButtonDisabled: Bool {
        switch coordinator.steamClientState {
        case .launching, .stopping: true
        case .runningVisible, .runningHidden: false
        case .stopped, .stale, .recoveryRequired: coordinator.isLaunchingSteam
        }
    }

    @ViewBuilder
    var steamInstallStatusView: some View {
        switch coordinator.steamInstallLifecycle {
        case .interrupted:
            VStack(spacing: 8) {
                Label("Steam installation was interrupted", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                HStack(spacing: 12) {
                    Button("Resume Installation") {
                        Task { await coordinator.installSteam() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Verify Completed Installation") {
                        coordinator.verifySteamInstallation()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 8)
        case .installing:
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Installing Steam…")
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

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
