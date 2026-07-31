// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MacsTeamNavigationCore

/// Production Inspect lane for the prefix page.
///
/// The view invokes this action for the Inspect button; production wires it
/// to the coordinator's canonical inspection authority exactly once per run.
/// Tests share this SAME action type (no source-string-only proof).
struct PrefixInspectAction {
    let run: () async -> Void

    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}

/// View for creating and inspecting the CloverPit Wine prefix
/// environment.
///
/// The coordinator (``UltimateSetupCoordinator``) creates the managed
/// directory structure and owns ALL verification evidence; the view only
/// derives its display from ``coordinator.prefixInspection``.
struct PrefixSetupView: View {
    let coordinator: UltimateSetupCoordinator

    /// The production Inspect lane (testable; view + tests share the type).
    var inspectAction: PrefixInspectAction

    @State private var isInspecting = false

    init(coordinator: UltimateSetupCoordinator) {
        self.coordinator = coordinator
        self.inspectAction = .production(coordinator: coordinator)
    }

    /// Verification evidence is coordinator-owned (bound to the canonical
    /// prefix root). The view NEVER holds its own inspection authority.
    private var inspection: PrefixInspection? {
        coordinator.prefixInspection
    }

    private var prefixPath: String {
        coordinator.prefixLayout?.root.path ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            statusSection
            inspectionSection
            Spacer()
            blockerBanner
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

            if coordinator.isCreatingPrefix {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                    Text("Creating environment…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.error {
                Label(error.localizedDescription, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button("Create CloverPit Environment") {
                    Task { await coordinator.createPrefix() }
                }
                .controlSize(.small)
                .disabled(coordinator.isCreatingPrefix)

                if coordinator.isCreatingPrefix {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                }

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

    @ViewBuilder
    private var blockerBanner: some View {
        if let result = coordinator.lastNavigationResult, !result.accepted, let blocker = result.blocker {
            Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var navigationButtons: some View {
        InstallerNavigationFooter(
            validator: DefaultInstallerNavigationValidator(),
            currentPage: .environment,
            onNavigate: { intent in
                await coordinator.send(intent)
            }
        )
    }

    // MARK: - Actions

    private func inspectPrefix() {
        guard coordinator.prefixLayout?.root != nil else { return }
        isInspecting = true
        Task {
            // Production Inspect lane → coordinator-owned canonical inspection.
            await inspectAction.run()
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
