// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Dedicated control-plane root under the MacSteam Application Support
/// namespace.
///
/// `state.json` is always the freshest snapshot (atomic replace). `events.ndjson`
/// is append-only structured events. Both live in the same trusted root so a
/// terminal client can read them without any IPC.
enum ControlPlaneRoot {
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/ControlPlane", isDirectory: true)
    }

    static var stateURL: URL { root.appendingPathComponent("state.json") }
    static var eventsURL: URL { root.appendingPathComponent("events.ndjson") }
}

/// Persistence for the control-plane mirror.
///
/// - `state.json`: written atomically (temp file + replace) on every content
///   change, never on identical content.
/// - `events.ndjson`: append-only; each event is exactly one JSON line.
public struct ControlPlaneStore {
    public init() {}

    /// Atomically replace `state.json` with the given snapshot.
    public func writeSnapshot(_ snapshot: ControlPlaneSnapshot) throws {
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let temp = ControlPlaneRoot.root
            .appendingPathComponent("state.json.tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(
            ControlPlaneRoot.stateURL,
            withItemAt: temp
        )
    }

    /// Append one event line to `events.ndjson`.
    public func appendEvent(_ event: ControlPlaneEvent) throws {
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lineData = try encoder.encode(event)
        lineData.append(0x0A)

        guard let handle = FileHandle(forWritingAtPath: ControlPlaneRoot.eventsURL.path) else {
            // First write: create the file and append.
            try lineData.write(to: ControlPlaneRoot.eventsURL, options: [])
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lineData)
    }

    /// Current snapshot, or nil when no snapshot has ever been written.
    public func readSnapshot() -> ControlPlaneSnapshot? {
        guard let data = try? Data(contentsOf: ControlPlaneRoot.stateURL) else { return nil }
        return try? JSONDecoder().decode(ControlPlaneSnapshot.self, from: data)
    }

    /// All event lines currently persisted, decoded best-effort.
    public func readEvents() -> [ControlPlaneEvent] {
        guard let data = try? Data(contentsOf: ControlPlaneRoot.eventsURL) else { return [] }
        let lines = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.compactMap { line in
            try? JSONDecoder().decode(ControlPlaneEvent.self, from: Data(line.utf8))
        }
    }

    /// Byte offset of the events stream (for tail --follow).
    public func eventsFileSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: ControlPlaneRoot.eventsURL.path) else {
            return 0
        }
        return (attrs[.size] as? UInt64) ?? 0
    }

    /// Read events bytes starting at the given offset (bounded).
    public func readEventsBytes(from offset: UInt64, limit: Int = 1_048_576) -> Data {
        guard let handle = FileHandle(forReadingAtPath: ControlPlaneRoot.eventsURL.path) else {
            return Data()
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: limit) ?? Data()
            return data
        } catch {
            return Data()
        }
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: ControlPlaneRoot.root,
            withIntermediateDirectories: true
        )
    }
}
