// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bounded aggregate timing history for ETA estimation (U1R18-R13-FIX1 §7).
///
/// Stores only bounded aggregate samples (no PID, path, account, identity).
/// ETA is unavailable until at least ``minimumSamples`` successful samples.
/// Prediction favours the median over the mean to resist outliers.
struct LaunchTimingStore: Equatable, Sendable {
    static let maxSamples = 10
    static let minimumSamples = 3

    /// Measurement domain keys persisted as bounded aggregates.
    enum Domain: String, CaseIterable, Codable, Sendable {
        case wineMS = "wine_ms"
        case steamProcessMS = "steam_process_ms"
        case steamReadyMS = "steam_ready_ms"
        case totalMS = "total_ms"
    }

    private(set) var samples: [Domain: [Int64]] = [:]

    init() {}

    /// Record a successful sample. Fails-closed: does not poison history with
    /// negative or non-finite values.
    mutating func record(_ domain: Domain, milliseconds ms: Int64) {
        guard ms >= 0 else { return }
        var list = samples[domain] ?? []
        list.append(ms)
        if list.count > Self.maxSamples {
            list.removeFirst(list.count - Self.maxSamples)
        }
        samples[domain] = list
    }

    /// Whether there is enough history to estimate the given domain.
    func canEstimate(_ domain: Domain) -> Bool {
        (samples[domain] ?? []).count >= Self.minimumSamples
    }

    /// Median fallback estimate (bounded). Returns nil when insufficient
    /// history or when the domain has no samples.
    func estimateMS(_ domain: Domain) -> Int64? {
        guard let list = samples[domain], list.count >= Self.minimumSamples else {
            return nil
        }
        let sorted = list.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        // Even count: average the two middle values (deterministic, bounded).
        let a = sorted[mid - 1]
        let b = sorted[mid]
        return (a + b) / 2
    }

    /// Estimated remaining milliseconds for a domain given elapsed so far.
    /// Never negative.
    func remainingMS(_ domain: Domain, elapsedMS: Int64) -> Int64? {
        guard let estimate = estimateMS(domain) else { return nil }
        return max(0, estimate - elapsedMS)
    }

    /// Bounded persistence payload — only aggregates, never identity.
    var persistencePayload: [String: Any] {
        var out: [String: Any] = ["schema_version": 1, "max_count": Self.maxSamples]
        for domain in Domain.allCases {
            out[domain.rawValue] = samples[domain] ?? []
        }
        return out
    }

    /// Decode a bounded payload produced by ``persistencePayload``.
    static func decode(_ payload: [String: Any]) -> LaunchTimingStore {
        var store = LaunchTimingStore()
        for domain in Domain.allCases {
            if let vals = payload[domain.rawValue] as? [Int64] {
                for v in vals { store.record(domain, milliseconds: v) }
            }
        }
        return store
    }
}