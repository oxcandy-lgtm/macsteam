// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Segmented launch timing (U1R18-R13-FIX1 §6).
///
/// All durations are measured with a monotonic clock and are never negative.
/// Steam process spawn and Steam usable/ready are tracked separately.
struct LaunchTiming: Equatable, Sendable {
    /// Monotonic segment durations in milliseconds.
    var winePreparationMS: Int64 = 0
    var steamProcessStartMS: Int64 = 0
    var steamReadyMS: Int64 = 0
    var cloverpitLaunchSubmittedMS: Int64? = nil
    var cloverpitWindowVisibleMS: Int64? = nil

    var totalToSteamReadyMS: Int64 {
        winePreparationMS + steamProcessStartMS + steamReadyMS
    }

    /// Record a named segment duration (monotonic, clamped non-negative).
    mutating func record(_ segment: LaunchTimingSegment, milliseconds ms: Int64) {
        let v = max(0, ms)
        switch segment {
        case .winePreparation: winePreparationMS = v
        case .steamProcessStart: steamProcessStartMS = v
        case .steamReady: steamReadyMS = v
        }
    }

    var totalToCloverpitVisibleMS: Int64? {
        guard let submit = cloverpitLaunchSubmittedMS, let visible = cloverpitWindowVisibleMS else {
            return nil
        }
        return totalToSteamReadyMS + submit + visible
    }

    /// Bounded diagnostics JSON — no PID, no path, no identity.
    var diagnosticJSON: String {
        let payload: [String: Any] = [
            "schema_version": 1,
            "wine_ms": winePreparationMS,
            "steam_process_ms": steamProcessStartMS,
            "steam_ready_ms": steamReadyMS,
            "total_ms": totalToSteamReadyMS,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

/// A single monotonic stopwatch segment.
struct LaunchStopwatch: Sendable {
    private let clock: any LaunchClock
    private let startMS: Int64

    init(clock: any LaunchClock) {
        self.clock = clock
        self.startMS = clock.nowMilliseconds()
    }

    /// Elapsed milliseconds since start; clamped to never be negative.
    func elapsedMS() -> Int64 {
        max(0, clock.nowMilliseconds() - startMS)
    }
}

/// Production-derived last-attempt startup breakdown (U1R18-R13-FIX1-FIX1 §6).
///
/// No PID, path, account, session identity, credentials, or raw arguments.
struct LaunchBreakdown: Equatable, Sendable {
    var winePreparationMS: Int64
    var steamProcessMS: Int64
    var steamReadyMS: Int64
    var totalMS: Int64
    var path: String?
    var failed: Bool

    /// Whether a segment has actually been measured (non-zero or explicitly
    /// begun). Zero with no prior attempt should be shown as pending.
    var anySegmentRecorded: Bool {
        winePreparationMS > 0 || steamProcessMS > 0 || steamReadyMS > 0
    }
}

/// Read-only startup telemetry for the live meter (U1R18-R13-FIX1-FIX3 §5/§6).
///
/// No PID, path, account, session identity, credentials, or raw arguments.
struct LaunchStartupTelemetry: Equatable, Sendable {
    var stage: LaunchPipelineStage
    var wineProgress: Double
    var wineCompleted: Int
    var wineTotal: Int
    var steamElapsedMS: Int64?
    var etaRemainingMS: Int64?
    var hasSufficientEtaHistory: Bool
    var validationPath: LaunchValidationPath?

    /// Truthful validation-path label, or nil when no decision exists yet.
    var pathLabel: String? {
        guard let p = validationPath else { return nil }
        return p == .fastValidation ? "Fast validation" : "Full validation"
    }
}