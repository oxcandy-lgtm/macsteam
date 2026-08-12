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

        // Global option: --timeout <seconds> (default 180s).
        var timeout: TimeInterval = 180
        var rest: [String] = []
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--timeout" {
                guard idx + 1 < args.count, let value = Double(args[idx + 1]) else {
                    return fail("--timeout requires a seconds value")
                }
                timeout = value
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
        case "next", "back", "retry":
            return dispatchControl(store, action: command, argument: nil, timeout: timeout)
        case "runtime":
            return runtime(store, rest: tail, timeout: timeout)
        case "prefix":
            return prefix(store, rest: tail, timeout: timeout)
        case "steam":
            return steam(store, rest: tail, timeout: timeout)
        case "cloverpit":
            return cloverpit(store, rest: tail, timeout: timeout)
        case "session":
            return session(store, rest: tail, timeout: timeout)
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

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
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