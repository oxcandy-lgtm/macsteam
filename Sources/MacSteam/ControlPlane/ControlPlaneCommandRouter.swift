// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MacsTeamControlPlane
import MacsTeamNavigationCore

/// AI-CP-STEP2: the SINGLE production router for terminal commands. SwiftUI and
/// the terminal drive the exact same coordinator intents through this surface.
///
/// Hard rules:
/// - NEVER assigns coordinator state directly — every action calls an existing
///   production method.
/// - Reads Step 1's `canonicalControlPlaneActions` gate BEFORE touching a
///   production method; a disabled action is rejected with `action_disabled`
///   so the terminal and GUI agree on exactly the same flags.
/// - Never emits arguments or raw paths into events/responses.
@MainActor
final class ControlPlaneCommandRouter {
    private let coordinator: UltimateSetupCoordinator

    init(coordinator: UltimateSetupCoordinator) {
        self.coordinator = coordinator
    }

    func perform(action: String, argument: String?) async -> ControlPlaneCommandResult {
        // Canonical action gate — same flags the GUI footer renders.
        let flags = coordinator.canonicalControlPlaneActions
        if let flag = flags[action], !flag.enabled {
            return ControlPlaneCommandResult(
                status: .rejected,
                error_code: "action_disabled",
                message: Self.redact(flag.disabled_reason ?? "Action is disabled.")
            )
        }

        switch action {
        case "next":
            await coordinator.send(.next)
            return .accepted
        case "back":
            await coordinator.send(.back)
            return .accepted
        case "retry":
            return await performRetry()
        case "runtime.select":
            return await performRuntimeSelect(argument: argument)
        case "prefix.prepare":
            await coordinator.createPrefix()
            return .accepted
        case "steam.recheck":
            await coordinator.recheckSteam()
            return .accepted
        case "steam.select_installer":
            return await performSelectInstaller(argument: argument)
        case "steam.install":
            await coordinator.installSteam()
            return .accepted
        case "steam.launch":
            await coordinator.launchWindowsSteam()
            return .accepted
        case "steam.diagnose":
            await coordinator.refreshSteamDiagnostics()
            return .accepted
        case "cloverpit.check":
            await coordinator.recheckCloverPit()
            return .accepted
        case "cloverpit.launch":
            await coordinator.launchCloverPit()
            return .accepted
        case "session.stop":
            _ = await coordinator.stopSession()
            return .accepted
        default:
            return ControlPlaneCommandResult(
                status: .rejected,
                error_code: "unknown_action",
                message: "Unknown action: \(action)."
            )
        }
    }

    // MARK: - Action implementations

    /// `retry` re-runs the CURRENT screen's production re-evaluation. No new
    /// state machine — it re-invokes the same production methods the screen's
    /// interactive buttons use.
    private func performRetry() async -> ControlPlaneCommandResult {
        switch coordinator.currentPage {
        case .runtime:
            await coordinator.inspectSystem()
            return .accepted
        case .environment:
            await coordinator.createPrefix()
            return .accepted
        case .steamInstaller:
            if coordinator.selectedInstaller != nil {
                await coordinator.installSteam()
                return .accepted
            }
            if coordinator.steamInstallEvidence.steamExePresent {
                await coordinator.recheckSteam()
                return .accepted
            }
            return ControlPlaneCommandResult(
                status: .rejected,
                error_code: "missing_installer",
                message: "No Steam installer selected and no existing installation to reconcile."
            )
        case .steamClient:
            await coordinator.recheckSteam()
            return .accepted
        case .cloverPit:
            await coordinator.recheckCloverPit()
            return .accepted
        case .diagnostics:
            return ControlPlaneCommandResult(
                status: .rejected,
                error_code: "no_retry_action",
                message: "No retry action on the diagnostics surface."
            )
        }
    }

    private func performRuntimeSelect(argument: String?) async -> ControlPlaneCommandResult {
        guard argument == "imported-wine" else {
            return ControlPlaneCommandResult(
                status: .rejected,
                error_code: "invalid_argument",
                message: "runtime.select only supports argument 'imported-wine'."
            )
        }
        let selected = await coordinator.selectRuntime(.importedWine)
        if selected { return .accepted }
        if coordinator.state == .runtimeRequired {
            return ControlPlaneCommandResult(
                status: .failed,
                error_code: "runtime_imported_wine_not_found",
                message: "No imported Wine runtime found."
            )
        }
        return ControlPlaneCommandResult(
            status: .failed,
            error_code: "runtime_selection_failed",
            message: coordinator.error.map { Self.redact($0.localizedDescription) }
                ?? "Runtime selection failed."
        )
    }

    private func performSelectInstaller(argument: String?) async -> ControlPlaneCommandResult {
        guard let path = argument, !path.isEmpty else {
            return ControlPlaneCommandResult(
                status: .rejected,
                error_code: "missing_argument",
                message: "steam.select_installer requires a path argument."
            )
        }
        await coordinator.selectSteamInstaller(URL(fileURLWithPath: path))
        if let error = coordinator.error {
            return ControlPlaneCommandResult(
                status: .failed,
                error_code: "installer_selection_failed",
                message: Self.redact(error.localizedDescription)
            )
        }
        return .accepted
    }

    /// Bound length and redact path-like fragments so a response never echoes
    /// a raw user-supplied installer path (mirrors the coordinator's rule).
    nonisolated private static func redact(_ message: String) -> String {
        let bounded = String(message.prefix(200))
        return bounded.replacingOccurrences(
            of: #"/[^\s/]+"#,
            with: "<sanitized>",
            options: .regularExpression
        )
    }
}