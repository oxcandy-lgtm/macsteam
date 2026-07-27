// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Root view for the MacSteam Ultimate U1 setup flow.
///
/// Replaces `LauncherView` as the app entry point during U1.  CrossOver-specific
/// selection is removed from the main UI (moved to advanced settings).
struct UltimateSetupView: View {
    @Bindable var coordinator: UltimateSetupCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await coordinator.inspectSystem() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CloverPit Ultimate")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("MacSteam Setup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            progressIndicator
        }
        .padding()
    }

    private var progressIndicator: some View {
        HStack(spacing: 4) {
            stepDot(index: 0, label: "Runtime", active: coordinator.state == .runtimeReady || beyond(.runtimeReady))
            stepDot(index: 1, label: "Prefix", active: coordinator.state == .prefixReady || beyond(.prefixReady))
            stepDot(index: 2, label: "Steam", active: coordinator.state == .steamReady || beyond(.steamReady))
            stepDot(index: 3, label: "Launch", active: coordinator.state == .cloverPitReady || beyond(.cloverPitReady))
        }
    }

    private func stepDot(index: Int, label: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(width: 44)
    }

    private func beyond(_ state: UltimateSetupState) -> Bool {
        let order: [UltimateSetupState] = [.inspecting, .runtimeRequired, .runtimeInvalid, .runtimeReady,
            .prefixRequired, .prefixReady, .steamInstallerRequired, .steamInstallerVerified,
            .steamInstallationPending, .steamReady, .cloverPitNotInstalled, .cloverPitReady,
            .launching, .launchSubmitted, .processObserved]
        guard let currentIdx = order.firstIndex(of: coordinator.state),
              let targetIdx = order.firstIndex(of: state) else { return false }
        return currentIdx > targetIdx
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .inspecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Inspecting system…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)

        case .runtimeRequired, .runtimeInvalid:
            RuntimeSetupView(coordinator: coordinator)

        case .runtimeReady:
            runtimeReadyView
            nextButton("Create Prefix →", action: { Task { await coordinator.createPrefix() } })

        case .prefixRequired:
            PrefixSetupView(coordinator: coordinator)

        case .prefixReady:
            prefixReadyView
            nextButton("Select Steam Installer →", action: { coordinator.state = .steamInstallerRequired })

        case .steamInstallerRequired:
            SteamSetupView(coordinator: coordinator)

        case .steamInstallerVerified:
            steamVerifiedView
            nextButton("Install Steam", action: { Task { await coordinator.installSteam() } })

        case .steamInstallationPending:
            steamPendingView

        case .steamReady:
            steamReadyView
            nextButton("Re-check CloverPit →", action: { Task { await coordinator.recheckCloverPit() } })

        case .cloverPitNotInstalled:
            cloverPitNotInstalledView

        case .cloverPitReady:
            CloverPitLaunchView(coordinator: coordinator)

        case .launching, .launchSubmitted, .processObserved:
            launchingView
        }
    }

    // MARK: - Subviews

    private var runtimeReadyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Runtime ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let inspection = coordinator.runtimeInspection {
                Group {
                    Text("Version: \(inspection.version ?? "unknown")")
                    Text("Arch: \(inspection.architecture ?? "unknown")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var prefixReadyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Prefix created", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("CloverPit environment ready")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var steamVerifiedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Installer verified", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
            if let installer = coordinator.selectedInstaller {
                Text("\(installer.fileName) (\(installer.fileSize / 1024 / 1024) MB)")
                    .font(.caption)
                Text("SHA-256: \(installer.sha256.prefix(16))…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var steamPendingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Installing Steam…")
            Text("Follow the Steam installer window.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Check again") {
                Task { await coordinator.recheckSteam() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
    }

    private var steamReadyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Steam ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Windows Steam detected in prefix.")
                .font(.caption)
            Text("Install CloverPit via Steam if not already installed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var cloverPitNotInstalledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("CloverPit not detected")
            Text("Install CloverPit via Steam, then check again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Re-check") {
                Task { await coordinator.recheckCloverPit() }
            }
            .buttonStyle(.borderedProminent)
            Button("Open Steam Library") {
                // User can launch Steam manually
                Task { await coordinator.launchCloverPit() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
    }

    private var launchingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(statusText)
                .font(.headline)
            if coordinator.state == .processObserved {
                Text("Waiting for game window…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("I see the CloverPit window") {
                    coordinator.confirmWindow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var statusText: String {
        switch coordinator.state {
        case .launching: return "Launching…"
        case .launchSubmitted: return "Launch submitted"
        case .processObserved: return "Process observed"
        default: return ""
        }
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }
}
