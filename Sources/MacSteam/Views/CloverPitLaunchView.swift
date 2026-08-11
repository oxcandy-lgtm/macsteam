// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MacsTeamNavigationCore

/// View for detecting CloverPit within a Steam installation and
/// launching it via the selected Wine runtime.
///
/// Detection and launch are driven through ``UltimateSetupCoordinator``,
/// which checks for the CloverPit game manifest and executable and
/// builds the launch plan via the session supervisor.
struct CloverPitLaunchView: View {
    let coordinator: UltimateSetupCoordinator
    /// The page's production presentation (footer page MUST come from here).
    let presentation: UltimatePagePresentation

    @State private var isDetecting = false
    @State private var isLaunching = false
    @State private var cloverPitDetected = false
    @State private var detectionDetail: String = ""
    @State private var launchResult: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            detectionSection
            launchSection
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
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("CloverPit")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Detect and launch CloverPit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Detection section

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detection")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                if isDetecting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                    Text("Checking Steam manifest…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if cloverPitDetected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CloverPit detected")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if !detectionDetail.isEmpty {
                            Text(detectionDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Tap Check to search for CloverPit")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if !cloverPitDetected && !isDetecting {
                Button("Check CloverPit") {
                    detectCloverPit()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Launch section

    @ViewBuilder
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch")
                .font(.subheadline)
                .fontWeight(.medium)

            if isLaunching {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                    Text("Preparing launch plan…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                launchProgressPanel
            } else if !launchResult.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(launchResult)
                        .font(.subheadline)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.secondary)
                    Text("Launch CloverPit after detection")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if cloverPitDetected && !isLaunching && launchResult.isEmpty {
                Button("Launch CloverPit") {
                    launchCloverPit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        // U1R18-R11-FIX1: the acceptance panel is driven by the authority's
        // presentation and is independent of any launch result. Showing it here
        // (after the launch card) guarantees it persists whether the launch
        // succeeded, is running, or the acceptance is blocked/invalidated.
        if coordinator.acceptancePresentation.isVisible {
            acceptancePanel
        }
    }

    // MARK: - Acceptance section (U1R18-R11)

    /// U1R18-R13-FIX1 §5/§6: launch progress + timing presentation.
    private var launchProgressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            let progress = coordinator.wineMilestones.progress
            let pct = Int((progress * 100).rounded())

            Text("Wine")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .tint(.blue)
            Text("\(coordinator.wineMilestones.completedCount) / \(WineMilestones.total)  \(pct)%")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if let eta = coordinator.steamReadyETA {
                Text("Steam elapsed: \(ms(eta.0))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let remaining = eta.1 {
                    Text("Estimated: ~\(ms(remaining)) remaining")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Estimated: Measuring…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func ms(_ value: Int64) -> String {
        String(format: "%.1f s", Double(value) / 1000.0)
    }

    private var acceptancePresentation: LocalAcceptancePresentation {
        coordinator.acceptancePresentation
    }

    @ViewBuilder
    private var acceptancePanel: some View {
        let presentation = acceptancePresentation
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime approval")
                .font(.subheadline)
                .fontWeight(.medium)

            statusRow(
                "Status",
                detail: presentation.title,
                ok: coordinator.acceptanceState == .accepted
            )
            statusRow(
                "Detail",
                detail: presentation.body,
                ok: false
            )
            statusRow(
                "Main menu confirmed",
                detail: coordinator.acceptanceMenuConfirmed ? "Confirmed" : "Pending",
                ok: coordinator.acceptanceMenuConfirmed
            )
            statusRow(
                "Input response confirmed",
                detail: coordinator.acceptanceInputConfirmed ? "Confirmed" : "Pending",
                ok: coordinator.acceptanceInputConfirmed
            )

            HStack(spacing: 8) {
                Button("Confirm Main Menu") {
                    _ = coordinator.confirmMainMenu()
                }
                .controlSize(.small)
                .disabled(!presentation.canConfirmMainMenu)

                Button("Confirm Input Response") {
                    _ = coordinator.confirmInputResponse()
                }
                .controlSize(.small)
                .disabled(!presentation.canConfirmInputResponse)

                Button("Complete Acceptance") {
                    Task {
                        _ = await coordinator.completeLocalAcceptance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!presentation.canComplete)
            }

            if let savedStatus = coordinator.savedLocalAcceptanceReceiptStatus {
                // U1R18-R12: historical evidence only. The saved receipt never
                // promotes the current run or satisfies this transaction.
                statusRow(
                    "Saved local receipt",
                    detail: "Saved: \(savedStatus). Historical evidence only — current run is not automatically accepted.",
                    ok: false
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(_ label: String, detail: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(label)
                .font(.caption)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func detectCloverPit() {
        isDetecting = true
        cloverPitDetected = false
        detectionDetail = ""
        Task {
            await coordinator.recheckCloverPit()
            let inspection = coordinator.cloverPitInspection
            cloverPitDetected = inspection?.isReady == true
            detectionDetail = inspection.map {
                $0.isReady ? "Manifest and executable found" : "Incomplete installation"
            } ?? ""
            isDetecting = false
        }
    }

    private func launchCloverPit() {
        isLaunching = true
        launchResult = ""
        Task {
            await coordinator.launchCloverPit()
            launchResult = coordinator.state == .launchSubmitted || coordinator.state == .processObserved
                ? "Launch submitted successfully"
                : "Launch failed"
            isLaunching = false
        }
    }
}
