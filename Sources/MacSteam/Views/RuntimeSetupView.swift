// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MacsTeamNavigationCore

/// View for selecting and inspecting a Wine compatibility runtime.
///
/// Supports both system-detected runtimes (``SystemWineRuntime``)
/// and user-imported runtimes via `NSOpenPanel`.  Displays the
/// results of ``RuntimeInspection`` including version, architecture,
/// capabilities, and any validation failures.
struct RuntimeSetupView: View {
    let coordinator: UltimateSetupCoordinator
    /// The page's production presentation (footer page MUST come from here).
    let presentation: UltimatePagePresentation

    @State private var selectedRuntimePath: String = ""
    @State private var inspectionResult: RuntimeInspection?
    @State private var isInspecting = false
    @State private var systemRuntimesAvailable = false

    private let systemDetector = SystemWineRuntime.self

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            runtimeSelection
            inspectionSection
            Spacer()
            blockerBanner
            navigationButtons
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            systemRuntimesAvailable = systemDetector.detectSystem()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compatibility Runtime")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Select or import a Wine runtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Runtime selection

    private var runtimeSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Available Runtimes")
                .font(.subheadline)
                .fontWeight(.medium)

            // MARK: Managed Wine (Coming later)
            HStack {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacsTeam Managed Wine")
                        .font(.subheadline)
                    Text("Coming later")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // MARK: Imported Wine Runtime
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.blue)
                Text("Imported Wine Runtime")
                    .font(.subheadline)
                Spacer()
                if !selectedRuntimePath.isEmpty {
                    Text(selectedRuntimePath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button("Select Wine Runtime…") {
                    selectRuntime()
                }
                .controlSize(.small)

                if !selectedRuntimePath.isEmpty {
                    Button("Clear") {
                        selectedRuntimePath = ""
                        inspectionResult = nil
                    }
                    .controlSize(.small)
                }
            }

            // MARK: System Wine
            if systemRuntimesAvailable {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("System Wine detected")
                        .font(.subheadline)
                    Spacer()
                    Button("Inspect Runtime") {
                        inspectSystemRuntime()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack {
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.secondary)
                    Text("No system Wine found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // MARK: CrossOver (optional proprietary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.secondary)
                    Text("CrossOver")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Optional")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("Optional third-party commercial runtime. Not required by MacsTeam Ultimate. May require a separate trial or license.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Inspection section

    @ViewBuilder
    private var inspectionSection: some View {
        if let result = inspectionResult {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inspection Results")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Group {
                    row(label: "Version", value: result.version ?? "—")
                    row(label: "Architecture", value: result.architecture ?? "—")
                    row(label: "Usable", value: result.isUsable ? "Yes" : "No")
                    row(label: "Capabilities", value: capabilitiesSummary(result.capabilities))
                }

                if !result.failures.isEmpty {
                    Divider()
                    Text("Failures")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)

                    ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if isInspecting {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                    .controlSize(.small)
                Text("Inspecting runtime…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Navigation

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

    // MARK: - Actions

    private func selectRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a Wine runtime directory"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectedRuntimePath = url.path
    }

    private func inspectSystemRuntime() {
        isInspecting = true
        inspectionResult = nil
        Task {
            await coordinator.inspectSystem()
            inspectionResult = coordinator.runtimeInspection
            isInspecting = false
        }
    }

    // MARK: - Helpers

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func capabilitiesSummary(_ caps: RuntimeCapabilities) -> String {
        var parts: [String] = []
        if caps.contains(.windowsProcess) { parts.append("Windows Process") }
        if caps.contains(.steamClient)    { parts.append("Steam Client") }
        if caps.contains(.isolatedPrefix) { parts.append("Isolated Prefix") }
        if caps.contains(.d3d)            { parts.append("Direct3D") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }
}
