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
    static var commandsRoot: URL { root.appendingPathComponent("commands") }
    static var inboxURL: URL { commandsRoot.appendingPathComponent("inbox") }
    static var outboxURL: URL { commandsRoot.appendingPathComponent("outbox") }
    static var heartbeatURL: URL { root.appendingPathComponent("heartbeat") }
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

    // MARK: - Command mailbox

    /// Atomically submit a command request to the inbox (CLI → app).
    public func writeCommandRequest(_ request: ControlPlaneCommandRequest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        try atomicWrite(data, to: ControlPlaneRoot.inboxURL.appendingPathComponent("\(request.id).json"), in: ControlPlaneRoot.inboxURL)
    }

    /// List all pending (not yet consumed) requests in the inbox. Decode
    /// failures are skipped and retried on the next poll — a concurrent writer
    /// may be mid-atomic-write.
    public func readPendingCommandRequests() -> [ControlPlaneCommandRequest] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: ControlPlaneRoot.inboxURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(ControlPlaneCommandRequest.self, from: data)
        }
    }

    /// Remove a consumed request. Ownership-safe: the consumer deletes the
    /// request BEFORE executing so a request is never processed twice.
    public func deleteCommandRequest(id: String) {
        try? FileManager.default.removeItem(
            at: ControlPlaneRoot.inboxURL.appendingPathComponent("\(id).json")
        )
    }

    /// Atomically write a command response to the outbox (app → CLI).
    public func writeCommandResponse(_ response: ControlPlaneCommandResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        try atomicWrite(data, to: ControlPlaneRoot.outboxURL.appendingPathComponent("\(response.id).json"), in: ControlPlaneRoot.outboxURL)
    }

    /// Read a response for a given request id, or nil while not yet written.
    public func readCommandResponse(id: String) -> ControlPlaneCommandResponse? {
        guard let data = try? Data(
            contentsOf: ControlPlaneRoot.outboxURL.appendingPathComponent("\(id).json")
        ) else { return nil }
        return try? JSONDecoder().decode(ControlPlaneCommandResponse.self, from: data)
    }

    /// Remove a response already consumed by the CLI.
    public func deleteCommandResponse(id: String) {
        try? FileManager.default.removeItem(
            at: ControlPlaneRoot.outboxURL.appendingPathComponent("\(id).json")
        )
    }

    // MARK: - Heartbeat

    /// Touch the heartbeat file so the CLI can distinguish a running app from a
    /// crashed one. The heartbeat carries no identity — mtime is the signal.
    public func writeHeartbeat() throws {
        let now = Date().timeIntervalSince1970
        let data = Data("\(now)\n".utf8)
        try atomicWrite(data, to: ControlPlaneRoot.heartbeatURL, in: ControlPlaneRoot.root)
    }

    /// Remove the heartbeat on graceful termination.
    public func removeHeartbeat() {
        try? FileManager.default.removeItem(at: ControlPlaneRoot.heartbeatURL)
    }

    /// Last heartbeat write time, or nil when never started.
    public func heartbeatLastModified() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: ControlPlaneRoot.heartbeatURL.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// App aliveness from heartbeat freshness. `staleAfter` is the age in
    /// seconds beyond which a heartbeat is considered unresponsive.
    public func appAliveness(now: Date = Date(), staleAfter: TimeInterval = 5) -> ControlPlaneAppAliveness {
        guard let modified = heartbeatLastModified() else { return .notRunning }
        let age = now.timeIntervalSince(modified)
        if age <= staleAfter { return .running }
        return .unresponsive(staleSeconds: age)
    }

    // MARK: - Private

    private func atomicWrite(_ data: Data, to url: URL, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
