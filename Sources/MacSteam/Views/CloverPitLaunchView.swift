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
            currentPage: .cloverPit,
            onNavigate: { intent in
                await coordinator.send(intent)
            }
        )
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
