// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Main setup wizard for the MacSteam Ultimate CloverPit flow.
///
/// Guides the user through four sequential steps:
///  1. Compatibility Runtime  (detect / select / validate)
///  2. Environment (Wine prefix creation and inspection)
///  3. Windows Steam  (installer download and installation)
///  4. CloverPit  (detection and launch)
///
/// Each step is represented by a collapsible section whose state is
/// driven by ``UltimateSetupState``.
struct UltimateSetupView: View {
    @State private var setupState: UltimateSetupState = .inspecting
    @State private var errorMessage: String = ""
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    stepSection(
                        number: 1,
                        title: "Compatibility Runtime",
                        state: runtimeStepState,
                        icon: "shippingbox"
                    )
                    stepSection(
                        number: 2,
                        title: "Environment",
                        state: prefixStepState,
                        icon: "folder"
                    )
                    stepSection(
                        number: 3,
                        title: "Windows Steam",
                        state: steamStepState,
                        icon: "steeringwheel"
                    )
                    stepSection(
                        number: 4,
                        title: "CloverPit",
                        state: cloverPitStepState,
                        icon: "gamecontroller"
                    )
                }
                .padding(.horizontal, 24)
            }

            Divider()
                .padding(.horizontal, 16)

            footnotes
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 520, height: 520)
        .sheet(isPresented: $showingDiagnostics) {
            // TODO: wire to real DiagnosticsView / GameManager
            Text("Diagnostics — not yet wired")
                .padding()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.2.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacSteam Ultimate")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("CloverPit Setup")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Step section

    private func stepSection(
        number: Int,
        title: String,
        state: StepState,
        icon: String
    ) -> some View {
        HStack(spacing: 12) {
            // Step number / status indicator
            ZStack {
                Circle()
                    .fill(state.tint)
                    .frame(width: 28, height: 28)
                Group {
                    switch state {
                    case .completed:
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    case .working:
                        ProgressView()
                            .scaleEffect(0.6)
                            .controlSize(.small)
                    case .pending:
                        Text("\(number)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    case .error:
                        Image(systemName: "exclamationmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step states

    /// Derived state for the Runtime step.
    private var runtimeStepState: StepState {
        switch setupState {
        case .inspecting:              return .working("Detecting available runtimes…")
        case .runtimeRequired:         return .pending("Select a Wine runtime to continue")
        case .runtimeInvalid:          return .error("Runtime failed validation")
        case .runtimeReady:            return .completed("Runtime ready")
        default:                       return .completed("Runtime ready")
        }
    }

    /// Derived state for the Environment (prefix) step.
    private var prefixStepState: StepState {
        switch setupState {
        case .inspecting, .runtimeRequired, .runtimeInvalid:
            return .pending("Waiting for runtime")
        case .runtimeReady:              return .pending("Create the CloverPit environment")
        case .prefixRequired:            return .pending("Create prefix to continue")
        case .prefixReady:               return .completed("Environment ready")
        case .steamInstallerRequired,
             .steamInstallerVerified,
             .steamInstallationPending,
             .steamReady,
             .cloverPitNotInstalled,
             .cloverPitReady,
             .launching,
             .launchSubmitted:
            return .completed("Environment ready")
        }
    }

    /// Derived state for the Steam step.
    private var steamStepState: StepState {
        switch setupState {
        case .inspecting, .runtimeRequired, .runtimeInvalid,
                .runtimeReady, .prefixRequired:
            return .pending("Waiting for environment")
        case .prefixReady:                 return .pending("Install Windows Steam")
        case .steamInstallerRequired:      return .pending("Download SteamSetup.exe")
        case .steamInstallerVerified:      return .pending("Run the installer")
        case .steamInstallationPending:    return .working("Installing Steam…")
        case .steamReady:                  return .completed("Steam ready")
        case .cloverPitNotInstalled,
             .cloverPitReady,
             .launching,
             .launchSubmitted:
            return .completed("Steam ready")
        }
    }

    /// Derived state for the CloverPit step.
    private var cloverPitStepState: StepState {
        switch setupState {
        case .inspecting, .runtimeRequired, .runtimeInvalid,
                .runtimeReady, .prefixRequired, .prefixReady,
                .steamInstallerRequired, .steamInstallerVerified,
                .steamInstallationPending:
            return .pending("Waiting for Steam")
        case .steamReady:                  return .pending("Detect CloverPit")
        case .cloverPitNotInstalled:       return .pending("Install CloverPit via Steam")
        case .cloverPitReady:              return .completed("Ready")
        case .launching:                   return .working("Launching…")
        case .launchSubmitted:             return .completed("Launched")
        }
    }

    // MARK: - Footnotes

    private var footnotes: some View {
        Group {
            if setupState == .cloverPitNotInstalled {
                Label("CloverPit was not found in the Steam library. Open Steam and install it, then recheck.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .runtimeInvalid = setupState {
                Label(errorMessage.isEmpty ? "The selected runtime did not pass validation." : errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button("View Diagnostics") {
                showingDiagnostics = true
            }
            .controlSize(.small)

            Spacer()

            if setupState == .cloverPitReady {
                Button("Launch CloverPit") {
                    // TODO: wire to GameManager.launch()
                    setupState = .launching
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Internal state representation

/// Lightweight representation of a single step's UI state.
private enum StepState {
    case completed(String)
    case working(String)
    case pending(String)
    case error(String)

    var detail: String {
        switch self {
        case .completed(let d), .working(let d),
             .pending(let d), .error(let d):
            return d
        }
    }

    var tint: Color {
        switch self {
        case .completed: return .green
        case .working:   return .blue
        case .pending:   return .gray
        case .error:     return .orange
        }
    }
}
