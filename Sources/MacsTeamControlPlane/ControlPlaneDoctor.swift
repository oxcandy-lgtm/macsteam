// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Doctor disposition of the current control-plane state.
///
/// - `ready`: CloverPit is running with its window visible — the goal.
/// - `actionable`: an enabled canonical action can advance the flow; see
///   `recommended_action`.
/// - `waiting`: a supervised operation is in flight; no action should be sent.
/// - `human_required`: only a bounded human interaction (e.g. Steam login /
///   installer path pick) can advance; see `blocker_code`.
/// - `blocked`: no safe autonomous path; `summary` explains why.
public enum ControlPlaneDoctorState: String, Codable, Sendable {
    case ready
    case actionable
    case waiting
    case human_required
    case blocked
}

/// Bounded, machine-readable doctor report. Derived ONLY from the canonical
/// snapshot, its action flags, the last structured error, and recent events —
/// never from paths, PIDs, credentials, or account identity.
public struct ControlPlaneDoctorReport: Codable, Equatable, Sendable {
    public var state: ControlPlaneDoctorState
    public var screen: String
    public var blocker_code: String?
    public var summary: String
    public var recommended_action: String?
    public var human_required: Bool
    public var last_error: ControlPlaneError?
    /// Bounded CloverPit install facts (doctor input echo for the terminal).
    public var cloverpit_facts: [String: Bool]?
    public var steam_client_state: String?

    public init(
        state: ControlPlaneDoctorState,
        screen: String,
        blocker_code: String? = nil,
        summary: String,
        recommended_action: String? = nil,
        human_required: Bool = false,
        last_error: ControlPlaneError? = nil,
        cloverpit_facts: [String: Bool]? = nil,
        steam_client_state: String? = nil
    ) {
        self.state = state
        self.screen = screen
        self.blocker_code = blocker_code
        self.summary = summary
        self.recommended_action = recommended_action
        self.human_required = human_required
        self.last_error = last_error
        self.cloverpit_facts = cloverpit_facts
        self.steam_client_state = steam_client_state
    }
}

/// Pure doctor evaluator — a diagnosis, NOT a state machine. The `run cloverpit`
/// driver and `macsteamctl doctor` both feed it the same inputs.
public struct ControlPlaneDoctor {
    public init() {}

    /// The exact goal test shared by doctor and driver.
    public static func isCloverPitRunningVisible(_ snapshot: ControlPlaneSnapshot) -> Bool {
        snapshot.cloverpit.running && snapshot.cloverpit.window_visible
    }

    /// Assess the current state. `recentEvents` should be the tail of the
    /// bounded event stream (most recent last).
    public func assess(
        snapshot: ControlPlaneSnapshot,
        recentEvents: [ControlPlaneEvent]
    ) -> ControlPlaneDoctorReport {
        let clover = snapshot.cloverpit
        let facts: [String: Bool] = [
            "manifest_present": clover.manifest_present,
            "install_directory_resolved": clover.install_directory_resolved,
            "executable_present": clover.executable_present,
            "canonical_install_present": clover.canonical_install_present,
            "download_payload_present": clover.download_payload_present,
        ]

        // 1. Goal reached.
        if Self.isCloverPitRunningVisible(snapshot) {
            return ControlPlaneDoctorReport(
                state: .ready,
                screen: snapshot.screen,
                summary: "CloverPit is running with its window visible.",
                cloverpit_facts: facts,
                steam_client_state: snapshot.steam.client_state
            )
        }

        // 2. Structured error present → exact blocker; retry when allowed.
        if let error = snapshot.last_error {
            let retryEnabled = snapshot.actions["retry"]?.enabled == true
            return ControlPlaneDoctorReport(
                state: retryEnabled ? .actionable : .blocked,
                screen: snapshot.screen,
                blocker_code: error.code,
                summary: "\(error.subsystem) \(error.code): \(error.message)",
                recommended_action: retryEnabled ? "retry" : nil,
                last_error: error,
                cloverpit_facts: facts,
                steam_client_state: snapshot.steam.client_state
            )
        }

        // 3. Human-only Steam interaction: Steam client is on-screen but the
        //    CloverPit session never started after a launch was accepted.
        if snapshot.steam.running && snapshot.steam.window_visible
            && !clover.running
            && lastAcceptedLaunch(from: recentEvents) != nil {
            return ControlPlaneDoctorReport(
                state: .human_required,
                screen: snapshot.screen,
                blocker_code: "steam_authentication_required",
                summary: "Steam is on screen but the CloverPit session did not start. A Steam login/Guard interaction is required.",
                human_required: true,
                cloverpit_facts: facts,
                steam_client_state: snapshot.steam.client_state
            )
        }

        // 3b. Steam installer path is a bounded human pick — never guessed.
        if snapshot.screen == "steamInstaller",
           snapshot.actions["steam.select_installer"]?.enabled == true,
           snapshot.steam.installed == false {
            return ControlPlaneDoctorReport(
                state: .human_required,
                screen: snapshot.screen,
                blocker_code: "steam_installer_path_required",
                summary: "A Steam installer path must be supplied before the install can run.",
                human_required: true,
                cloverpit_facts: facts,
                steam_client_state: snapshot.steam.client_state
            )
        }

        // 4. Waiting: a supervised operation is in flight.
        if snapshot.session.running || snapshot.installer.active {
            // If CloverPit/Steam process launched but window not yet visible,
            // wait for the supervisor to observe it. If a session is running but
            // nothing is advancing and session.stop is safely enabled, let the
            // driver auto-stop (driver policy), so surface as actionable.
            if snapshot.actions["session.stop"]?.enabled == true, canAutoStop(snapshot) {
                return ControlPlaneDoctorReport(
                    state: .actionable,
                    screen: snapshot.screen,
                    summary: "A supervised session is running without progress; stopping it is safe.",
                    recommended_action: "session.stop",
                    cloverpit_facts: facts,
                    steam_client_state: snapshot.steam.client_state
                )
            }
            let what = snapshot.installer.active ? "an installer operation" : "a supervised session"
            return ControlPlaneDoctorReport(
                state: .waiting,
                screen: snapshot.screen,
                summary: "Waiting on \(what) to settle.",
                cloverpit_facts: facts,
                steam_client_state: snapshot.steam.client_state
            )
        }

        // 5. Actionable: pick the first enabled CloverPit-forward action.
        if let action = recommendedAction(snapshot) {
            let summary: String
            switch action {
            case "session.stop":
                summary = "A stale operation blocks progress and session.stop is safely enabled."
            case "runtime.select":
                summary = "No runtime selected; selecting imported Wine."
            case "prefix.prepare":
                summary = "Wine prefix is not bound; preparing it."
            case "steam.recheck":
                summary = "Steam payload present but not synchronized; re-checking."
            case "cloverpit.check":
                summary = "CloverPit install state unresolved; re-checking."
            case "steam.launch":
                summary = "Steam is ready to launch for setup."
            case "cloverpit.launch":
                summary = "CloverPit is ready; launching the session."
            case "steam.install":
                summary = "A Steam installer is selected; running the install."
            case "retry":
                summary = "Retrying the current production re-evaluation."
            default:
                summary = "Navigation/action is available."
            }
            return ControlPlaneDoctorReport(
                state: .actionable,
                screen: snapshot.screen,
                summary: summary,
                recommended_action: action,
                cloverpit_facts: facts,
                steam_client_state: snapshot.steam.client_state
            )
        }

        // 6. Blocked with guidance from disabled reasons.
        let disabled = disabledReasons(snapshot)
        return ControlPlaneDoctorReport(
            state: .blocked,
            screen: snapshot.screen,
            blocker_code: "no_action",
            summary: disabled.isEmpty
                ? "No enabled action can advance on \(snapshot.screen)."
                : "No enabled action can advance on \(snapshot.screen). " + disabled.joined(separator: " "),
            cloverpit_facts: facts,
            steam_client_state: snapshot.steam.client_state
        )
    }

    // MARK: - Recommendation

    /// Deterministic per-screen CloverPit-forward action, always a gated
    /// canonical action id (only enabled actions are returned).
    func recommendedAction(_ snapshot: ControlPlaneSnapshot) -> String? {
        func enabled(_ id: String) -> Bool {
            snapshot.actions[id]?.enabled == true
        }

        switch snapshot.screen {
        case "runtime":
            if !snapshot.runtime.selected, enabled("runtime.select") { return "runtime.select" }
            if enabled("retry") { return "retry" }
            if enabled("next") { return "next" }
            return enabled("back") ? "back" : nil
        case "environment":
            if !snapshot.prefix.bound, enabled("prefix.prepare") { return "prefix.prepare" }
            if enabled("retry") { return "retry" }
            if enabled("next") { return "next" }
            return enabled("back") ? "back" : nil
        case "steamInstaller":
            if enabled("steam.install") { return "steam.install" }
            if snapshot.steam.installed, enabled("next") { return "next" }
            if enabled("steam.recheck") { return "steam.recheck" }
            if enabled("retry") { return "retry" }
            if enabled("next") { return "next" }
            return enabled("back") ? "back" : nil
        case "steamClient":
            // steam.recheck is enabled whenever the surface is active, so it
            // must not shadow the forward path once Steam is complete.
            if snapshot.steam.lifecycle != "verifiedComplete", enabled("steam.recheck") { return "steam.recheck" }
            if enabled("next") { return "next" }
            if enabled("steam.launch") { return "steam.launch" }
            if enabled("retry") { return "retry" }
            return enabled("back") ? "back" : nil
        case "cloverPit":
            // cloverpit.check is enabled whenever the surface is active; prefer
            // the launch once the inspection already proves readiness.
            if snapshot.cloverpit.ready, enabled("cloverpit.launch") { return "cloverpit.launch" }
            if enabled("cloverpit.check") { return "cloverpit.check" }
            if enabled("retry") { return "retry" }
            if enabled("next") { return "next" }
            return enabled("back") ? "back" : nil
        default:
            // diagnostics and anything else.
            if enabled("retry") { return "retry" }
            if enabled("next") { return "next" }
            return enabled("back") ? "back" : nil
        }
    }

    /// Whether a stale running session may be auto-stopped by the driver.
    private func canAutoStop(_ snapshot: ControlPlaneSnapshot) -> Bool {
        // Never auto-stop a healthy CloverPit or Steam process that just needs
        // visibility observation — only stop when the goal target is idle and
        // a session lingers.
        if snapshot.cloverpit.running || snapshot.steam.window_visible { return false }
        return true
    }

    private func lastAcceptedLaunch(from events: [ControlPlaneEvent]) -> String? {
        for event in events.reversed() {
            guard event.event == "command_accepted",
                  let action = event.action,
                  action == "cloverpit.launch" || action == "steam.launch" else { continue }
            return action
        }
        return nil
    }

    /// Bounded capitalization of why each relevant action is disabled.
    private func disabledReasons(_ snapshot: ControlPlaneSnapshot) -> [String] {
        let ids = ["runtime.select", "prefix.prepare", "steam.recheck", "steam.install",
                   "steam.launch", "cloverpit.check", "cloverpit.launch", "next"]
        var reasons: [String] = []
        for id in ids {
            guard let flag = snapshot.actions[id], !flag.enabled else { continue }
            if let reason = flag.disabled_reason {
                reasons.append("\(id): \(reason)")
            }
        }
        return reasons
    }
}