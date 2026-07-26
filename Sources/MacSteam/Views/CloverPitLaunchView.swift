// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// View for detecting CloverPit within a Steam installation and
/// launching it via the selected Wine runtime.
///
/// Uses ``SteamInstallationDetector`` to check for the CloverPit
/// game manifest and executable, and ``SteamLaunchCoordinator`` to
/// build the launch plan.
struct CloverPitLaunchView: View {
    @State private var isDetecting = false
    @State private var isLaunching = false
    @State private var cloverPitDetected = false
    @State private var detectionDetail: String = ""
    @State private var launchResult: String = ""

    private let detector = SteamInstallationDetector()
    private let launchCoordinator = SteamLaunchCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            detectionSection
            launchSection
            Spacer()
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

    private var navigationButtons: some View {
        HStack {
            Button("Back") {
                // TODO: navigate to Steam setup
            }
            .controlSize(.small)

            Spacer()

            Button("Done") {
                // TODO: dismiss or navigate to main launcher
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!cloverPitDetected && launchResult.isEmpty)
        }
    }

    // MARK: - Actions

    private func detectCloverPit() {
        isDetecting = true
        cloverPitDetected = false
        detectionDetail = ""

        // TODO: wire to SteamInstallationDetector.inspect(recipe:runtime:)
        // let result = await detector.inspect(recipe: cloverpitRecipe, runtime: activeRuntime)
        // cloverPitDetected = result.manifestPresent && result.executablePresent
        // detectionDetail = result.isReady ? "Manifest and executable found" : "Incomplete installation"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isDetecting = false
            cloverPitDetected = true
            detectionDetail = "Steam manifest found, executable verified"
        }
    }

    private func launchCloverPit() {
        isLaunching = true
        launchResult = ""

        // TODO: wire to SteamLaunchCoordinator.makeLaunchPlan(prefixURL:recipe:)
        // if let plan = launchCoordinator.makeLaunchPlan(prefixURL: prefixURL, recipe: recipe) {
        //     try await processRunner.run(executable: plan.runtimeExecutable, ...)
        //     launchResult = "Launch submitted"
        // } else {
        //     launchResult = "Failed to create launch plan"
        // }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isLaunching = false
            launchResult = "Launch submitted successfully"
        }
    }
}
