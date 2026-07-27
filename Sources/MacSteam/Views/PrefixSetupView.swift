// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// View for creating and inspecting the CloverPit Wine prefix
/// environment.
///
/// Uses ``PrefixManager`` to create the managed directory structure
/// and ``PrefixInspector`` to validate the resulting environment.
struct PrefixSetupView: View {
    let coordinator: UltimateSetupCoordinator

    @State private var prefixPath: String = ""
    @State private var inspection: PrefixInspection?
    @State private var isCreating = false
    @State private var isInspecting = false
    @State private var creationError: String? = nil

    private let prefixManager = PrefixManager()
    private let prefixInspector = PrefixInspector()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            statusSection
            inspectionSection
            Spacer()
            navigationButtons
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Environment Setup")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Create and verify the Wine prefix for CloverPit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Status section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prefix Status")
                .font(.subheadline)
                .fontWeight(.medium)

            if prefixPath.isEmpty {
                HStack {
                    Image(systemName: "square.dashed")
                        .foregroundStyle(.secondary)
                    Text("No environment created yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.blue)
                        Text(prefixPath)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if let insp = inspection {
                        HStack(spacing: 12) {
                            statusBadge(label: "drive_c",
                                        ok: insp.driveCExists)
                            statusBadge(label: "Wine prefix",
                                        ok: insp.hasWinePrefix)
                            statusBadge(label: "Valid",
                                        ok: insp.isValid)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if isCreating {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                    Text("Creating environment…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = creationError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button("Create CloverPit Environment") {
                    createPrefix()
                }
                .controlSize(.small)
                .disabled(isCreating)

                if !prefixPath.isEmpty {
                    Button("Inspect Prefix") {
                        inspectPrefix()
                    }
                    .controlSize(.small)
                    .disabled(isInspecting)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Inspection section

    @ViewBuilder
    private var inspectionSection: some View {
        if let insp = inspection {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inspection Details")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Group {
                    detailRow(label: "drive_c",       value: insp.driveCExists ? "Present" : "Missing")
                    detailRow(label: "Wine prefix",   value: insp.hasWinePrefix ? "Present" : "Missing")
                    detailRow(label: "Steam detected", value: insp.hasSteam ? "Yes" : "No")
                    detailRow(label: "Valid",           value: insp.isValid ? "Yes" : "No")
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            Button("Back") {
                // TODO: navigate to runtime setup
            }
            .controlSize(.small)

            Spacer()

            Button("Next") {
                // TODO: advance to Steam installer setup
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(inspection?.isValid != true)
        }
    }

    // MARK: - Actions

    private func createPrefix() {
        isCreating = true
        creationError = nil
        Task {
            await coordinator.createPrefix()
            await MainActor.run {
                isCreating = false
                if let error = coordinator.error {
                    creationError = error.localizedDescription
                } else {
                    prefixPath = coordinator.prefixInspection.map { _ in "Created" } ?? ""
                    inspection = coordinator.prefixInspection
                }
            }
        }
    }

    private func inspectPrefix() {
        guard !prefixPath.isEmpty else { return }
        isInspecting = true

        // TODO: wire to PrefixInspector with real URL
        // let url = URL(fileURLWithPath: prefixPath)
        // inspection = prefixInspector.inspect(url: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isInspecting = false
        }
    }

    // MARK: - Helpers

    private func statusBadge(label: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(ok ? .green : .red)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
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
}
