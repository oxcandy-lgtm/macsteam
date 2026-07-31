// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MacsTeamNavigationCore

/// Root view for the MacSteam Ultimate U1 setup flow.
///
/// # Navigation authority
/// The rendered page is derived EXCLUSIVELY from ``coordinator.currentPage``
/// through ``UltimatePageResolver`` — the header title, step number, and
/// body all come from the same page value. `coordinator.state` is only used
/// for in-page progress display (never for page dispatch).
struct UltimateSetupView: View {
    @Bindable var coordinator: UltimateSetupCoordinator
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !coordinator.installerLog.isEmpty {
                Divider()
                installerLogView
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await coordinator.inspectSystem() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(coordinator: coordinator)
        }
    }

    // MARK: - Installer Log

    private var installerLogView: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Installer Log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(coordinator.installerLog, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Stable identity: enumerate by offset, never by content.
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal)
                    .id("logBottom")
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding([.horizontal, .bottom])
                .onChange(of: coordinator.installerLog) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var logLines: [String] {
        coordinator.installerLog
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppBrand.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(pageTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Installer session ID badge
            if !coordinator.installerID.isEmpty {
                Text("#\(coordinator.installerID)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
#if DEBUG
            // Debug-only: process identity for diagnostics
            Text("PID \(ProcessInfo.processInfo.processIdentifier)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
#endif
            progressIndicator
            Button("Settings", systemImage: "gearshape") {
                showingSettings = true
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding()
    }

    /// The page's production presentation contract — the SINGLE source for
    /// content identity, title, step, footer page, and Steam mode.
    private var presentation: UltimatePagePresentation {
        UltimatePageResolver.presentation(for: coordinator.currentPage)
    }

    /// Title + step derived from the SAME presentation as the body.
    private var pageTitle: String {
        "Step \(presentation.stepNumber) of "
            + "\(UltimatePageResolver.pageCount) — \(presentation.title)"
    }

    private var progressIndicator: some View {
        HStack(spacing: 4) {
            ForEach(InstallerPage.allCases, id: \.self) { page in
                stepDot(
                    label: shortLabel(for: page),
                    active: UltimatePageResolver.stepNumber(for: page) <= presentation.stepNumber
                )
            }
        }
    }

    private func shortLabel(for page: InstallerPage) -> String {
        switch page {
        case .runtime: return "Runtime"
        case .environment: return "Prefix"
        case .steamInstaller: return "Installer"
        case .steamClient: return "Steam"
        case .cloverPit: return "CloverPit"
        case .diagnostics: return "Diag"
        }
    }

    private func stepDot(label: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(width: 48)
    }

    // MARK: - Content (single authority: currentPage via presentation)

    @ViewBuilder
    private var content: some View {
        switch presentation.contentKind {
        case .runtime:
            RuntimeSetupView(coordinator: coordinator)
        case .environment:
            PrefixSetupView(coordinator: coordinator)
        case .steamInstaller:
            // Production-separated installer surface (page .steamInstaller).
            SteamSetupView(
                coordinator: coordinator,
                mode: presentation.steamMode ?? .installer
            )
        case .steamClient:
            // Production-separated client surface (page .steamClient).
            SteamSetupView(
                coordinator: coordinator,
                mode: presentation.steamMode ?? .client
            )
        case .cloverPit:
            CloverPitLaunchView(coordinator: coordinator)
        case .diagnostics:
            diagnosticsPageView
        }
    }

    // MARK: - Diagnostics page (complete navigation + evidence)

    private var diagnosticsPageView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.title3)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox(label: Label("Page completion evidence", systemImage: "checklist")) {
                        VStack(alignment: .leading, spacing: 4) {
                            let completion = coordinator.computePageCompletion()
                            ForEach(InstallerPage.allCases, id: \.self) { page in
                                HStack {
                                    Text("\(UltimatePageResolver.title(for: page))")
                                        .font(.caption)
                                    Spacer()
                                    Text(completion[page] == true ? "complete" : "incomplete")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(completion[page] == true ? .green : .secondary)
                                }
                            }
                        }
                        .padding(4)
                    }

                    GroupBox(label: Label("Runtime evidence", systemImage: "shippingbox.fill")) {
                        VStack(alignment: .leading, spacing: 4) {
                            row("Type", coordinator.runtimeSourceType ?? "—")
                            row("Version", coordinator.runtimeExactVersion ?? "—")
                            row("Architecture", coordinator.runtimeArchitecture ?? "—")
                            row("Usable", coordinator.runtimeInspection?.isUsable == true ? "yes" : "no")
                        }
                        .padding(4)
                    }

                    GroupBox(label: Label("Canonical prefix evidence", systemImage: "folder.fill")) {
                        VStack(alignment: .leading, spacing: 4) {
                            row("Layout", coordinator.prefixLayout?.root.path ?? "none")
                            row("Inspection",
                                coordinator.prefixInspection == nil ? "none"
                                    : (coordinator.prefixInspection?.isValid == true ? "valid" : "invalid"))
                            row("Bound to canonical root",
                                coordinator.canonicalPrefixEvidenceValid ? "yes" : "no")
                        }
                        .padding(4)
                    }

                    GroupBox(label: Label("Steam evidence", systemImage: "steeringwheel")) {
                        VStack(alignment: .leading, spacing: 4) {
                            row("Lifecycle", coordinator.steamInstallLifecycle.rawValue)
                            row("Installed",
                                coordinator.steamInspection?.steamInstalled == true ? "yes" : "no")
                            row("Client state", "\(coordinator.steamClientState)")
                        }
                        .padding(4)
                    }

                    GroupBox(label: Label("CloverPit", systemImage: "gamecontroller.fill")) {
                        VStack(alignment: .leading, spacing: 4) {
                            row("Readiness",
                                coordinator.cloverPitInspection?.isReady == true ? "ready" : "not ready")
                        }
                        .padding(4)
                    }

                    GroupBox(label: Label("Environment", systemImage: "info.circle")) {
                        VStack(alignment: .leading, spacing: 4) {
                            row("Instance",
                                coordinator.installerID.isEmpty ? "—" : "#\(coordinator.installerID)")
                            row("Current page", coordinator.currentPage.rawValue)
                            row("Coordinator state", coordinator.state.rawValue)
#if DEBUG
                            row("PID", "\(ProcessInfo.processInfo.processIdentifier)")
#endif
                        }
                        .padding(4)
                    }

                    GroupBox(label: Label("Installer log", systemImage: "doc.plaintext")) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Spacer()
                                Button("Copy Log") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        coordinator.installerLog, forType: .string
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(4)
                    }
                }
                .padding(.vertical, 4)
            }

            // Diagnostics participates in the canonical navigation lane:
            // Back → CloverPit via coordinator.send(.back).
            InstallerNavigationFooter(
                validator: DefaultInstallerNavigationValidator(),
                currentPage: coordinator.currentPage,
                onNavigate: { intent in
                    await coordinator.send(intent)
                }
            )
        }
        .padding(24)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
