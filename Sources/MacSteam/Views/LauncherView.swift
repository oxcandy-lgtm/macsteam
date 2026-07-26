// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Main launcher screen.
///
/// Displays the selected game, runtime state, Steam state, game
/// installation state, and a primary action button that changes
/// based on the current state.
struct LauncherView: View {
    @ObservedObject var manager: GameManager
    @State private var showingDiagnostics = false
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            gameSummary
            statusList
            Divider()
            primaryButton
            secondaryButtons
        }
        .padding(24)
        .frame(width: 480)
        .task {
            await manager.inspect()
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView(manager: manager)
        }
        .disabled(isWorking)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(AppBrand.displayName)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    // MARK: - Game summary

    private var gameSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.currentRecipe?.displayName ?? "—")
                    .font(.title3)
                    .fontWeight(.medium)
                if let recipe = manager.currentRecipe {
                    Text("Steam App \(recipe.store.appId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusBadge(for: manager.state)
        }
    }

    // MARK: - Status list

    private var statusList: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusRow(
                label: "Compatibility runtime",
                detail: statusForRuntime(manager.state),
                icon: "shippingbox"
            )
            StatusRow(
                label: "Windows Steam",
                detail: statusForSteam(manager.state),
                icon: "steeringwheel"
            )
            StatusRow(
                label: "Game installation",
                detail: statusForGame(manager.state),
                icon: "doc"
            )
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Primary button

    @ViewBuilder
    private var primaryButton: some View {
        switch manager.state {
        case .inspecting:
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                    .controlSize(.small)
                Text("Inspecting…")
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .runtimeMissing, .runtimeInvalid:
            Button("Select compatibility runtime") {
                showFilePicker()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

        case .storeMissing, .gameNotInstalled:
            Button("Open Windows Steam") {
                awaitWithBusy {
                    await manager.openStore()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

        case .ready:
            Button("Launch CloverPit") {
                awaitWithBusy {
                    await manager.launch()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .frame(maxWidth: .infinity)

        case .launching:
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                    .controlSize(.small)
                Text("Launching…")
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .failed:
            Button("Recheck") {
                awaitWithBusy {
                    await manager.inspect()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Secondary buttons

    private var secondaryButtons: some View {
        HStack {
            Button("Diagnostics") {
                manager.refreshDiagnostics()
                showingDiagnostics = true
            }
            .controlSize(.small)

            Button("Recheck") {
                awaitWithBusy {
                    await manager.inspect()
                }
            }
            .controlSize(.small)

            if case .storeMissing = manager.state {
                Button("Open Windows Steam") {
                    awaitWithBusy {
                        await manager.openStore()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Status text helpers

    private func statusForRuntime(_ state: LauncherState) -> String {
        switch state {
        case .inspecting: return "Checking…"
        case .runtimeMissing: return "Missing"
        case .runtimeInvalid: return "Invalid"
        case .storeMissing, .gameNotInstalled, .launching: return "—"
        case .ready: return "Ready"
        case .failed: return "Error"
        }
    }

    private func statusForSteam(_ state: LauncherState) -> String {
        switch state {
        case .inspecting: return "Checking…"
        case .runtimeMissing, .runtimeInvalid: return "—"
        case .storeMissing: return "Missing"
        case .gameNotInstalled: return "Ready"
        case .ready: return "Ready"
        case .launching: return "—"
        case .failed: return "Error"
        }
    }

    private func statusForGame(_ state: LauncherState) -> String {
        switch state {
        case .inspecting: return "Checking…"
        case .runtimeMissing, .runtimeInvalid, .storeMissing: return "—"
        case .gameNotInstalled: return "Not installed"
        case .ready: return "Ready"
        case .launching: return "—"
        case .failed: return "Error"
        }
    }

    private func statusBadge(for state: LauncherState) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .inspecting: return ("…", .gray)
            case .runtimeMissing, .runtimeInvalid, .storeMissing,
                    .gameNotInstalled, .failed: return ("⚠", .orange)
            case .ready: return ("✓", .green)
            case .launching: return ("…", .blue)
            }
        }()
        return Text(text)
            .font(.title3)
            .foregroundStyle(color)
            .accessibilityLabel(launcherStateDescription(state))
    }

    private func launcherStateDescription(_ state: LauncherState) -> String {
        switch state {
        case .inspecting: return "Inspecting system"
        case .runtimeMissing: return "Compatibility runtime not found"
        case .runtimeInvalid: return "Compatibility runtime is invalid"
        case .storeMissing: return "Windows Steam not found"
        case .gameNotInstalled: return "Game is not installed"
        case .ready: return "Ready to launch"
        case .launching: return "Launching game"
        case .failed: return "An error occurred"
        }
    }

    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select CrossOver.app"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            isWorking = true
            defer { isWorking = false }
            _ = manager.runtimeLocator.locateRuntime(at: url)
            await manager.inspect()
        }
    }

    private func awaitWithBusy(_ action: @escaping () async -> Void) {
        Task {
            isWorking = true
            defer { isWorking = false }
            await action()
        }
    }
}

// MARK: - Supporting view

private struct StatusRow: View {
    let label: String
    let detail: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(detail == "Ready" ? .green : .secondary)
        }
    }
}
