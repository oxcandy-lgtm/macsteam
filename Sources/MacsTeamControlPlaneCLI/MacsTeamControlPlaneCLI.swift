// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MacsTeamControlPlane

/// `macsteamctl` — the MacsTeam terminal control plane.
///
/// A deliberately tiny file-mailbox client: writes a canonical request into
/// `commands/inbox/`, the running app consumes it on the MainActor through the
/// SAME production intents the GUI uses, and the CLI reads the response from
/// `commands/outbox/`. No daemon, no socket, no XPC.
@main
struct MacsTeamControlPlaneCLI {
    static func main() {
        exit(run(Array(CommandLine.arguments.dropFirst())))
    }

    static func run(_ args: [String]) -> Int32 {
        let store = ControlPlaneStore()

        // Global option: --timeout <seconds> (per-command default).
        var timeoutOverride: TimeInterval?
        var rest: [String] = []
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--timeout" {
                guard idx + 1 < args.count, let value = Double(args[idx + 1]) else {
                    return fail("--timeout requires a seconds value")
                }
                timeoutOverride = value
                idx += 2
            } else {
                rest.append(arg)
                idx += 1
            }
        }

        guard let command = rest.first else { return usage() }
        let tail = Array(rest.dropFirst())

        switch command {
        case "status":
            return status(store, rest: tail)
        case "events":
            return events(store, rest: tail)
        case "doctor":
            return doctor(store, rest: tail)
        case "run":
            return runTarget(store, rest: tail, timeout: timeoutOverride ?? 600)
        case "next", "back", "retry":
            return dispatchControl(store, action: command, argument: nil, timeout: timeoutOverride ?? 180)
        case "runtime":
            return runtime(store, rest: tail, timeout: timeoutOverride ?? 180)
        case "prefix":
            return prefix(store, rest: tail, timeout: timeoutOverride ?? 180)
        case "steam":
            return steam(store, rest: tail, timeout: timeoutOverride ?? 180)
        case "cloverpit":
            return cloverpit(store, rest: tail, timeout: timeoutOverride ?? 180)
        case "session":
            return session(store, rest: tail, timeout: timeoutOverride ?? 180)
        default:
            return usage()
        }
    }

    // MARK: - Read commands

    static func status(_ store: ControlPlaneStore, rest: [String]) -> Int32 {
        if let snapshot = store.readSnapshot() {
            print(encode(snapshot))
            return 0
        }
        switch store.appAliveness() {
        case .notRunning:
            return emitError(code: "app_not_running")
        case .unresponsive:
            return emitError(code: "app_unresponsive")
        case .running:
            return emitError(code: "no_snapshot")
        }
    }

    static func events(_ store: ControlPlaneStore, rest: [String]) -> Int32 {
        let follow = rest.contains("--follow")
        let initial = store.readEventsBytes(from: 0)
        if !initial.isEmpty {
            FileHandle.standardOutput.write(initial)
            if initial.last != 0x0A {
                print()
            }
        }
        guard follow else { return 0 }

        var offset = UInt64(initial.count)
        while true {
            Thread.sleep(forTimeInterval: 0.3)
            let data = store.readEventsBytes(from: offset)
            guard !data.isEmpty else { continue }
            FileHandle.standardOutput.write(data)
            offset += UInt64(data.count)
            FileHandle.standardOutput.synchronizeFile()
        }
    }

    // MARK: - Doctor

    static func doctor(_ store: ControlPlaneStore, rest: [String]) -> Int32 {
        guard let snapshot = store.readSnapshot() else {
            switch store.appAliveness() {
            case .notRunning:
                return emitError(code: "app_not_running")
            case .unresponsive:
                return emitError(code: "app_unresponsive")
            case .running:
                return emitError(code: "no_snapshot")
            }
        }
        let events = Array(store.readEvents().suffix(20))
        let report = ControlPlaneDoctor().assess(snapshot: snapshot, recentEvents: events)
        print(encode(report))
        return report.state == .ready ? 0 : 1
    }

    // MARK: - Driver (`run cloverpit`)

    /// Drive the app from its current state to `cloverpit.running &&
    /// cloverpit.window_visible` entirely through the existing command mailbox.
    /// Resumes from wherever the app currently is — never restarts from zero.
    static func runTarget(_ store: ControlPlaneStore, rest: [String], timeout: TimeInterval) -> Int32 {
        guard rest.first == "cloverpit" else {
            return fail("usage: macsteamctl run cloverpit [--timeout <seconds>]")
        }
        return runCloverPit(store: store, overallTimeout: timeout)
    }

    private static func runCloverPit(store: ControlPlaneStore, overallTimeout: TimeInterval) -> Int32 {
        let start = Date()
        var humanInterventionUsed = false

        // No-progress guard: same recommendation + unchanged snapshot 3 times.
        var lastAction: String?
        var lastFingerprint = ""
        var noProgress = 0

        while true {
            if Date().timeIntervalSince(start) > overallTimeout {
                return emitError(code: "flow_timeout", message: "CloverPit not reached within \(Int(overallTimeout))s.")
            }

            switch store.appAliveness() {
            case .notRunning:
                return emitError(code: "app_not_running")
            case .unresponsive(let stale):
                return emitError(code: "app_unresponsive", message: String(format: "Heartbeat stale for %.0fs.", stale))
            case .running:
                break
            }

            guard let snapshot = store.readSnapshot() else {
                return emitError(code: "no_snapshot", message: "No state.json yet.")
            }

            // Success: the only goal.
            if snapshot.cloverpit.running && snapshot.cloverpit.window_visible {
                print(encodeDict(successPayload(snapshot: snapshot, humanInterventionUsed: humanInterventionUsed)))
                return 0
            }

            let events = Array(store.readEvents().suffix(30))
            let report = ControlPlaneDoctor().assess(snapshot: snapshot, recentEvents: events)

            switch report.state {
            case .ready:
                print(encodeDict(successPayload(snapshot: snapshot, humanInterventionUsed: humanInterventionUsed)))
                return 0
            case .human_required:
                if report.blocker_code == "steam_authentication_required" {
                    // Grace: the launch was accepted but the Steam/game window may
                    // still be starting. Only confirm the human boundary once the
                    // accepted launch is older than the bounded grace window.
                    let lastLaunchTS = lastAcceptedLaunchTimestamp(events)
                    let grace = 45.0
                    if let lastLaunchTS {
                        let settled = Date().timeIntervalSince1970 - lastLaunchTS
                        if settled < grace {
                            Thread.sleep(forTimeInterval: 5)
                            continue
                        }
                    }
                }
                return emitHumanRequired(code: report.blocker_code ?? "human_required", snapshot: snapshot)
            case .waiting:
                // No action while a supervised operation settles.
                if fingerprint(snapshot) == lastFingerprint {
                    noProgress += 1
                } else {
                    noProgress = 0
                }
                if noProgress >= 3 {
                    return emitError(code: "flow_stalled", message: report.summary)
                }
                progressPrint("[driver] waiting — \(report.summary)")
                lastFingerprint = fingerprint(snapshot)
                lastAction = nil
                Thread.sleep(forTimeInterval: 3)
                continue
            case .actionable, .blocked:
                guard let action = report.recommended_action else {
                    // Blocked with no recommendation — stall guard on stable state.
                    if fingerprint(snapshot) == lastFingerprint {
                        noProgress += 1
                    } else {
                        noProgress = 0
                    }
                    if noProgress >= 3 {
                        return emitError(code: "flow_stalled", message: report.summary)
                    }
                    progressPrint("[driver] blocked — \(report.summary)")
                    lastFingerprint = fingerprint(snapshot)
                    lastAction = nil
                    Thread.sleep(forTimeInterval: 3)
                    continue
                }

                if action == "steam.select_installer" {
                    return emitHumanRequired(code: "steam_installer_path_required", snapshot: snapshot)
                }

                let before = fingerprint(snapshot)
                if action == lastAction && before == lastFingerprint {
                    noProgress += 1
                    if noProgress >= 3 {
                        return emitError(code: "flow_stalled", message: "\(report.summary) Action \(action) made no progress 3 times.")
                    }
                } else {
                    noProgress = 0
                }
                lastAction = action
                lastFingerprint = before

                progressPrint("[driver] \(action) — \(report.summary)")
                let code = sendAndWait(store, action: action, argument: nil, timeout: 180)
                if code != 0 {
                    // Rejected/failed — let the doctor re-read the new state.
                    progressPrint("[driver] \(action) rejected/failed (\(code)); re-assessing.")
                    Thread.sleep(forTimeInterval: 2)
                }
            }

            // Wait for an observable state/event change (bounded).
            waitForChange(store, from: lastFingerprint, timeout: 150)
        }
    }

    /// Poll until the snapshot fingerprint changes or the events log grows
    /// (an accepted command produces mail-stream events even when the bounded
    /// snapshot stays flat), within the bounded settle window.
    private static func waitForChange(_ store: ControlPlaneStore, from oldFingerprint: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let eventWatermark = store.eventsFileSize()
        while Date() < deadline {
            if store.eventsFileSize() != eventWatermark {
                return
            }
            if let snapshot = store.readSnapshot(), fingerprint(snapshot) != oldFingerprint {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Stable per-iteration fingerprint of the bounded snapshot fields (excludes
    /// the live installer log message so idle progress is not confused with
    /// advancement).
    private static func fingerprint(_ s: ControlPlaneSnapshot) -> String {
        let actions = s.actions.values.sorted { $0.id < $1.id }
            .map { "\($0.id)=\($0.enabled)/\($0.target)" }
            .joined(separator: ",")
        return [
            s.screen, s.setup_state,
            s.runtime.type, "\(s.runtime.selected)", "\(s.runtime.real_load_healthy)",
            "\(s.prefix.bound)", "\(s.prefix.valid)",
            "\(s.steam.installed)", s.steam.lifecycle, "\(s.steam.running)", "\(s.steam.window_visible)", s.steam.client_state,
            "\(s.cloverpit.ready)", "\(s.cloverpit.running)", "\(s.cloverpit.window_visible)", s.cloverpit.install_state,
            s.session.purpose, "\(s.session.running)", "\(s.session.window_visible)",
            s.last_transition.map { "\($0.action)->\($0.to):\($0.accepted)" } ?? "-",
            s.last_error?.code ?? "-",
            actions,
        ].joined(separator: "|")
    }

    private static func lastAcceptedLaunchTimestamp(_ events: [ControlPlaneEvent]) -> Double? {
        for event in events.reversed() {
            guard event.event == "command_accepted",
                  let action = event.action,
                  action == "cloverpit.launch" || action == "steam.launch" else { continue }
            return event.ts
        }
        return nil
    }

    private static func successPayload(snapshot: ControlPlaneSnapshot, humanInterventionUsed: Bool) -> [String: Any] {
        [
            "status": "running_visible",
            "target": "cloverpit",
            "screen": snapshot.screen,
            "running": snapshot.cloverpit.running,
            "window_visible": snapshot.cloverpit.window_visible,
            "human_intervention_used": humanInterventionUsed,
        ]
    }

    private static func emitHumanRequired(code: String, snapshot: ControlPlaneSnapshot) -> Int32 {
        let payload: [String: Any] = [
            "state": "human_required",
            "code": code,
            "screen": snapshot.screen,
            "target": "cloverpit",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"state\":\"human_required\",\"code\":\"\(code)\"}")
        }
        return 1
    }

    // MARK: - Control commands

    static func runtime(_ store: ControlPlaneStore, rest: [String], timeout: TimeInterval) -> Int32 {
        guard rest.first == "select", rest.count >= 2 else {
            return fail("usage: macsteamctl runtime select imported-wine")
        }
        let type = rest[1]
        guard type == "imported-wine" else {
            return fail("runtime select supports only 'imported-wine'")
        }
        return dispatchControl(store, action: "runtime.select", argument: type, timeout: timeout)
    }

    static func prefix(_ store: ControlPlaneStore, rest: [String], timeout: TimeInterval) -> Int32 {
        guard rest.first == "prepare" else {
            return fail("usage: macsteamctl prefix prepare")
        }
        return dispatchControl(store, action: "prefix.prepare", argument: nil, timeout: timeout)
    }

    static func steam(_ store: ControlPlaneStore, rest: [String], timeout: TimeInterval) -> Int32 {
        guard let sub = rest.first else {
            return fail("usage: macsteamctl steam recheck | select-installer <path> | install | launch")
        }
        switch sub {
        case "recheck":
            return dispatchControl(store, action: "steam.recheck", argument: nil, timeout: timeout)
        case "select-installer":
            guard rest.count >= 2 else {
                return fail("usage: macsteamctl steam select-installer <path-to-SteamSetup.exe>")
            }
            return dispatchControl(store, action: "steam.select_installer", argument: rest[1], timeout: timeout)
        case "install":
            return dispatchControl(store, action: "steam.install", argument: nil, timeout: timeout)
        case "launch":
            return dispatchControl(store, action: "steam.launch", argument: nil, timeout: timeout)
        default:
            return fail("unknown steam subcommand '\(sub)'")
        }
    }

    static func cloverpit(_ store: ControlPlaneStore, rest: [String], timeout: TimeInterval) -> Int32 {
        guard let sub = rest.first else {
            return fail("usage: macsteamctl cloverpit check | launch")
        }
        switch sub {
        case "check":
            return dispatchControl(store, action: "cloverpit.check", argument: nil, timeout: timeout)
        case "launch":
            return dispatchControl(store, action: "cloverpit.launch", argument: nil, timeout: timeout)
        default:
            return fail("unknown cloverpit subcommand '\(sub)'")
        }
    }

    static func session(_ store: ControlPlaneStore, rest: [String], timeout: TimeInterval) -> Int32 {
        guard rest.first == "stop" else {
            return fail("usage: macsteamctl session stop")
        }
        return dispatchControl(store, action: "session.stop", argument: nil, timeout: timeout)
    }

    // MARK: - Mailbox plumbing

    static func dispatchControl(_ store: ControlPlaneStore, action: String, argument: String?, timeout: TimeInterval) -> Int32 {
        switch store.appAliveness() {
        case .notRunning:
            return emitError(code: "app_not_running")
        case .unresponsive(let stale):
            return emitError(code: "app_unresponsive", message: String(format: "Heartbeat stale for %.0fs.", stale))
        case .running:
            break
        }
        return sendAndWait(store, action: action, argument: argument, timeout: timeout)
    }

    static func sendAndWait(_ store: ControlPlaneStore, action: String, argument: String?, timeout: TimeInterval) -> Int32 {
        let id = UUID().uuidString
        do {
            try store.writeCommandRequest(ControlPlaneCommandRequest(id: id, action: action, argument: argument))
        } catch {
            return emitError(code: "request_write_failed", message: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = store.readCommandResponse(id: id) {
                store.deleteCommandResponse(id: id)
                print(encode(response))
                return response.status == .accepted ? 0 : 1
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Stale-safe: drop any late response; the app deletes old requests itself.
        store.deleteCommandResponse(id: id)
        return emitError(code: "command_timeout", message: "No response within \(Int(timeout))s.")
    }

    // MARK: - Output helpers

    static func usage() -> Int32 {
        let text = """
        macsteamctl — MacsTeam terminal control plane

        Read:
          macsteamctl status [--json]
          macsteamctl events [--follow]

        Operate (invokes the same production intents as the GUI):
          macsteamctl next
          macsteamctl back
          macsteamctl retry
          macsteamctl runtime select imported-wine
          macsteamctl prefix prepare
          macsteamctl steam recheck
          macsteamctl steam select-installer <path-to-SteamSetup.exe>
          macsteamctl steam install
          macsteamctl steam launch
          macsteamctl cloverpit check
          macsteamctl cloverpit launch
          macsteamctl session stop

        Options:
          --timeout <seconds>   wait up to N seconds for a command response (default 180)
        """
        print(text)
        return 1
    }

    static func fail(_ message: String) -> Int32 {
        fputs("macsteamctl: \(message)\n", stderr)
        return 1
    }

    /// Streamed progress line (flushed immediately so it survives pipes).
    static func progressPrint(_ message: String) {
        print(message)
        fflush(stdout)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func encodeDict(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func emitError(code: String, message: String? = nil) -> Int32 {
        var dict: [String: String] = ["code": code]
        if let message { dict["message"] = message }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"code\":\"\(code)\"}")
        }
        return 1
    }
}