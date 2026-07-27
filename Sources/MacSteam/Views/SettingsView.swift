// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Advanced settings for MacSteam.
///
/// **U1R7:** CrossOver opt-in is session-scoped and NOT persisted across restarts.
/// Session state is the single source of truth (from GameSessionSupervisor.state).
struct SettingsView: View {
    @Bindable var coordinator: UltimateSetupCoordinator

    var body: some View {
        Form {
            Section("Sessions") {
                sessionStatusView

                if coordinator.sessionSupervisorIsRunning {
                    HStack {
                        if coordinator.sessionSupervisorIsStopping {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                            Text("Stopping CloverPit…\nWaiting for the Wine session to exit.")
                                .font(.caption)
                        } else {
                            Button("Stop & Relaunch", role: .destructive) {
                                Task { await coordinator.stopSession() }
                            }
                        }
                    }
                }
            }

            Section("Runtime") {
                Toggle(
                    "Include CrossOver",
                    systemImage: "wineglass",
                    isOn: Binding(
                        get: { coordinator.commercialPolicy == .explicitUserOptIn },
                        set: { enabled in
                            coordinator.commercialPolicy = enabled ? .explicitUserOptIn : .disabled
                        }
                    )
                )

                Text("Session-scoped only. Not persisted across app restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Graphics") {
                LabeledContent("Preferred backend") {
                    Text(coordinator.graphicsBackend?.rawValue ?? "Auto")
                        .font(.caption.monospaced())
                }
            }

            Section("Verification") {
                Button("Re-run system inspection") {
                    Task { await coordinator.inspectSystem() }
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Session status

    @ViewBuilder
    private var sessionStatusView: some View {
        switch coordinator.sessionSupervisorState {
        case .idle, .stopped:
            LabeledContent("Status") {
                Text("Idle")
                    .foregroundStyle(.secondary)
            }

        case .launching:
            LabeledContent("Status") {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Launching…")
                        .foregroundStyle(.blue)
                }
            }

        case .runningUnknown:
            LabeledContent("Status") {
                Text("Running (window not confirmed)")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CloverPit runtime is active.")
                    .font(.caption)
                Text("The game window has not been confirmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .runningVisible:
            LabeledContent("Status") {
                Text("Running")
                    .foregroundStyle(.green)
            }

        case .runningHidden:
            LabeledContent("Status") {
                Text("Running (background)")
                    .foregroundStyle(.orange)
            }
            Text("Steam or CloverPit is still running in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .stopping:
            LabeledContent("Status") {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Stopping…")
                        .foregroundStyle(.red)
                }
            }

        case .recoveryRequired(let msg):
            LabeledContent("Status") {
                Text("Recovery required")
                    .foregroundStyle(.red)
            }
            Text(msg)
                .font(.caption)

        case .failed(let msg):
            LabeledContent("Status") {
                Text("Failed")
                    .foregroundStyle(.red)
            }
            Text(msg)
                .font(.caption)
        }

        // PID — Debug only
        if let session = coordinator.activeSession {
#if DEBUG
            LabeledContent("PID") {
                Text("\(session.rootPID)")
                    .font(.caption.monospaced())
            }
#endif

            LabeledContent("Started") {
                Text(session.startedAt, style: .time)
            }
        }
    }
}
