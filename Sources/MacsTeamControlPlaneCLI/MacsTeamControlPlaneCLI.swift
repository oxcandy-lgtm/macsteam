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

        // Steam-side finalization poll: staged CloverPit payload + Steam
        // running. Bounded grace before the human boundary is exposed: 30s once
        // the Steam window is visible, or a 150s in-motion ceiling without any
        // visibility observation (the terminal cannot observe finalization).
        var visibleGraceSince: Date?
        var inMotionGraceSince: Date?
        let visibleGrace: TimeInterval = 30
        let inMotionCeiling: TimeInterval = 150

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
                return emitHumanRequired(code: report.blocker_code ?? "human_required", snapshot: snapshot)
            case .blocked where report.blocker_code == "steam_visible_error":
                // A real, terminal-readable Steam error is on screen — never
                // keep polling a doomed finalization. Emit the exact blocker.
                return emitError(code: "steam_visible_error", message: report.summary)
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

                // Steam finalization poll: a staged CloverPit payload with Steam
                // running or launching must NOT be collapsed by the no-progress
                // guard. Poll the read-only inspection at a bounded cadence; the
                // human boundary is exposed only after: (a) the Steam window is
                // visible for `visibleGrace` while still staged, or (b) Steam has
                // stayed in motion for `inMotionCeiling` without any visibility
                // observation to conclude progress.
                let steamInMotion = snapshot.steam.running
                    || snapshot.steam.client_state == "launching"
                    || snapshot.steam.client_state == "stopping"
                if action == "cloverpit.check",
                   steamInMotion,
                   !snapshot.cloverpit.ready,
                   !snapshot.cloverpit.running {
                    if snapshot.steam.window_visible {
                        let since = visibleGraceSince ?? Date()
                        visibleGraceSince = since
                        inMotionGraceSince = nil
                        let elapsed = Date().timeIntervalSince(since)
                        if elapsed >= visibleGrace {
                            return emitHumanRequired(code: "steam_interaction_required", snapshot: snapshot)
                        }
                        progressPrint("[driver] Steam visible, CloverPit staged (\(Int(elapsed))s/\(Int(visibleGrace))s); polling cloverpit.check.")
                    } else {
                        let since = inMotionGraceSince ?? Date()
                        inMotionGraceSince = since
                        visibleGraceSince = nil
                        let elapsed = Date().timeIntervalSince(since)
                        if elapsed >= inMotionCeiling {
                            return emitHumanRequired(code: "steam_interaction_required", snapshot: snapshot)
                        }
                        progressPrint("[driver] Steam in motion, CloverPit staged (\(Int(elapsed))s/\(Int(inMotionCeiling))s); polling cloverpit.check.")
                    }
                    _ = sendAndWait(store, action: "cloverpit.check", argument: nil, timeout: 180)
                    Thread.sleep(forTimeInterval: 7)
                    continue
                }
                visibleGraceSince = nil
                inMotionGraceSince = nil

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
        var payload: [String: Any] = [
            "status": "human_required",
            "code": code,
            "steam_window_visible": snapshot.steam.window_visible,
            "cloverpit_ready": snapshot.cloverpit.ready,
            "screen": snapshot.screen,
            "target": "cloverpit",
        ]
        if let visible = snapshot.steam.visible_error, visible.present {
            var errorDict: [String: Any] = ["present": true]
            if let source = visible.source { errorDict["source"] = source }
            if let title = visible.title { errorDict["title"] = title }
            if let message = visible.message { errorDict["message"] = message }
            payload["visible_error"] = errorDict
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"status\":\"human_required\",\"code\":\"\(code)\"}")
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
            return fail("usage: macsteamctl steam recheck | select-installer <path> | install | launch | diagnose")
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
        case "diagnose":
            return steamDiagnose(store, timeout: timeout)
        default:
            return fail("unknown steam subcommand '\(sub)'")
        }
    }

    // MARK: - Steam diagnose

    /// `macsteamctl steam diagnose --json`: one command answers — is Steam
    /// running? is its window visible? what error is ACTUALLY on screen? what
    /// do stderr / Steam's own logs say? The on-screen error is read live in
    /// THIS process (Accessibility first, OCR fallback) against ownership-
    /// grounded Steam windows only — never a timeout guess, never a question
    /// to the user.
    static func steamDiagnose(_ store: ControlPlaneStore, timeout: TimeInterval) -> Int32 {
        // Fresh app-side capture first (snapshot visible_error/logs refresh).
        // Suppress the dispatch envelope: diagnose prints ONE document.
        _ = sendAndWaitSilent(store, action: "steam.diagnose", argument: nil, timeout: timeout)

        var running = false
        var windowVisible = false
        var clientState = "stopped"
        if let snapshot = store.readSnapshot() {
            running = snapshot.steam.running
            windowVisible = snapshot.steam.window_visible
            clientState = snapshot.steam.client_state
        }

        let prefixes = discoverSteamPrefixRoots()
        let ownedWindows = SteamLiveDiagnostics.prefixGroundedSteamWindows(prefixRoots: prefixes)
        let ownerPIDs = ownedWindows.map(\.ownerPID)

        var visibleError: [String: Any] = ["present": false]
        if !ownerPIDs.isEmpty {
            let accessibility = SteamLiveDiagnostics.readAccessibility(ownerPIDs: ownerPIDs)
            var title: String?
            var message: String?
            var permission: String?
            if accessibility.permissionDenied {
                permission = "accessibility"
            } else if let readTitle = accessibility.title {
                title = SteamLiveDiagnostics.redact(readTitle, maxLength: 200)
                message = accessibility.messages.first.map {
                    SteamLiveDiagnostics.redact($0, maxLength: 200)
                }
            } else if let first = accessibility.messages.first {
                message = SteamLiveDiagnostics.redact(first, maxLength: 200)
            }

            // OCR fallback when Accessibility could not read dialog body text.
            if title == nil && message == nil && permission == nil {
                let ocr = ocrReadBlocking(ownerPIDs: ownerPIDs)
                if ocr.permissionDenied {
                    permission = "screen_recording"
                } else if let first = ocr.texts.first {
                    message = SteamLiveDiagnostics.redact(first, maxLength: 200)
                }
            }

            if title != nil || message != nil {
                visibleError = ["present": true, "source": "accessibility"]
                if let title { visibleError["title"] = title }
                if let message { visibleError["message"] = message }
            } else if let permission {
                visibleError = ["present": false, "permission_required": permission]
            }
        }

        let logDirectory = steamLogsDirectory(in: prefixes)
        var recentErrors: [[String: String]] = []
        for entry in SteamLiveDiagnostics.scanSteamLogs(directory: logDirectory) {
            recentErrors.append([
                "source": entry.source,
                "component": entry.component,
                "severity": entry.severity,
                "message": entry.message,
            ])
        }

        let payload: [String: Any] = [
            "running": running,
            "window_visible": windowVisible,
            "client_state": clientState,
            "visible_error": visibleError,
            "recent_errors": recentErrors,
        ]
        print(encodeDict(payload))
        return 0
    }

    /// Canonical MacSteam Wine prefixes (identity-path grounding for window
    /// ownership in `steam diagnose`).
    private static func discoverSteamPrefixRoots() -> [String] {        let root = NSHomeDirectory() + "/Library/Application Support/MacSteam/Prefixes"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .map { root + "/" + $0 }
    }

    private static func steamLogsDirectory(in prefixes: [String]) -> URL? {
        for prefix in prefixes {
            let candidates = [
                URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/Program Files (x86)/Steam/logs"),
                URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/Program Files/Steam/logs"),
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Bridge the async ScreenCaptureKit OCR read into the synchronous CLI.
    private static func ocrReadBlocking(ownerPIDs: [Int32]) -> SteamOCRRead {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OCRReadBox()
        Task {
            box.value = await SteamLiveDiagnostics.readOCR(ownerPIDs: ownerPIDs)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class OCRReadBox: @unchecked Sendable {
        var value = SteamOCRRead(available: false, texts: [], permissionDenied: false)
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

    /// Like ``sendAndWait`` but does not print the dispatch envelope; used by
    /// composite commands that emit a single document (e.g. `steam diagnose`).
    static func sendAndWaitSilent(_ store: ControlPlaneStore, action: String, argument: String?, timeout: TimeInterval) -> Int32 {
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
          macsteamctl steam diagnose
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