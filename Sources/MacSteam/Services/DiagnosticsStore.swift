// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Local‐only diagnostics store.
///
/// Entries stay on the local machine and are never transmitted.
final class DiagnosticsStore: @unchecked Sendable {

    private var entries: [DiagnosticEntry] = []
    private let maxEntries = 100

    /// Append a new diagnostic entry.
    func append(_ message: String, entryType: DiagnosticEntry.EntryType = .info) {
        let entry = DiagnosticEntry(
            timestamp: Date(),
            type: entryType,
            message: PathRedactor.fullyRedact(message)
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }
    }

    /// Return the most recent entries.
    func recentEntries(limit: Int = 50) -> [DiagnosticEntry] {
        Array(entries.suffix(limit))
    }

    /// Clear all entries.
    func clear() {
        entries.removeAll()
    }
}

/// A single diagnostic log entry.
struct DiagnosticEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let type: EntryType
    let message: String

    enum EntryType: String, Equatable, Sendable {
        case info
        case warning
        case error
    }
}
