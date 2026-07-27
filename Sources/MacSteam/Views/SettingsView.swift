// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Advanced settings for MacSteam.
///
/// **U1R6:** CrossOver is disabled by default. The user must explicitly
/// opt in via the toggle below to make CrossOver discoverable.
struct SettingsView: View {
    @Bindable var coordinator: UltimateSetupCoordinator

    @AppStorage("commercialRuntimePolicy")
    private var storedPolicy: String = CommercialRuntimePolicy.disabled.rawValue

    var body: some View {
        Form {
            Section("Runtime") {
                Toggle(
                    "Include CrossOver",
                    systemImage: "wineglass",
                    isOn: Binding(
                        get: { coordinator.commercialPolicy == .explicitUserOptIn },
                        set: { enabled in
                            coordinator.commercialPolicy = enabled ? .explicitUserOptIn : .disabled
                            storedPolicy = coordinator.commercialPolicy.rawValue
                        }
                    )
                )

                Text("CrossOver is a third-party commercial runtime. "
                     + "MacSteam does not bundle, require, or recommend it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if coordinator.commercialPolicy == .explicitUserOptIn {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("CrossOver will be offered as the lowest-priority "
                             + "option, after Managed / Imported / System Wine.")
                            .font(.caption)
                    }
                }
            }

            Section("Sessions") {
                if let session = coordinator.activeSession {
                    LabeledContent("Status") {
                        Text("Running")
                            .foregroundStyle(.green)
                    }
                    LabeledContent("Started") {
                        Text(session.startedAt, style: .time)
                    }
                    LabeledContent("PID") {
                        Text("\(session.rootPID)")
                            .font(.caption.monospaced())
                    }
                    Button("Stop Session", role: .destructive) {
                        Task { await coordinator.stopSession() }
                    }
                } else {
                    LabeledContent("Status") {
                        Text("Idle")
                            .foregroundStyle(.secondary)
                    }
                }
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
}
