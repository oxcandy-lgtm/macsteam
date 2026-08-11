// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fixed events that the secure Steam logger may record.
/// Free-form strings are never accepted — every log entry
/// must be one of these known cases.
enum SecureSteamLogEvent: Sendable, Equatable {
    case libraryVisibilityConfirmed
    case steamProcessObserved
    case cloverPitManifestDetected
    case cloverPitExecutableDetected
    case launchSubmitted
    case sensitiveInputRejected(SteamSensitiveCategory)
}

/// A secure logger that only accepts typed events.
///
/// No free-form strings, no raw paths, no environment dumps.
/// All logged content is fixed text derived from the event type.
actor SecureSteamLogger {
    private var events: [SecureSteamLogEvent] = []
    private var categoryCounts: [SteamSensitiveCategory: Int] = [:]

    /// Record a known event.
    func record(_ event: SecureSteamLogEvent) {
        events.append(event)
        if case .sensitiveInputRejected(let cat) = event {
            categoryCounts[cat, default: 0] += 1
        }
    }

    /// Human-readable description of the recorded events.
    func summary() -> String {
        let total = events.count
        let rejected = categoryCounts.values.reduce(0, +)
        var parts: [String] = ["\(total) event(s) recorded"]
        if rejected > 0 {
            parts.append("\(rejected) sensitive input(s) rejected")
            for (cat, count) in categoryCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                parts.append("  \(cat.rawValue): \(count)")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Total number of recorded events.
    func eventCount() -> Int { events.count }

    /// Reset all recorded events.
    func reset() {
        events = []
        categoryCounts = [:]
    }
}

/// Legacy redactor — deprecated.  Use `SecureSteamLogger` instead.
struct SteamLogRedactor: Sendable {
    static let deprecated = true
}
