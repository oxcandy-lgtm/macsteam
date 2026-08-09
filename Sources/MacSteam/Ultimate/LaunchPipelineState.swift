// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Explicit launch pipeline stage model (U1R18-R13-FIX1 §4).
///
/// The UI shows which of Wine / Steam / CloverPit the launch is at. Stages are
/// advanced in a fixed order; any out-of-order transition is a fail-closed
/// error rather than a silent accept.
enum LaunchPipelineStage: Int, CaseIterable, Sendable, Equatable {
    case idle = 0
    case validatingRuntime
    case probingWine
    case resolvingPrefix
    case validatingSteam
    case preparingWine
    case startingSteam
    case waitingForSteam
    case launchingCloverPit
    case waitingForCloverPit
    case ready
    case failed
}

/// Production-evidence-bound Wine milestones (U1R18-R13-FIX1 §5.1).
///
/// Progress percentage is derived ONLY from completed deterministic milestones
/// over the total milestone count — never from a wall-clock fake timer.
struct WineMilestones: Equatable, Sendable {
    var runtimeResolved = false
    var runtimeCapabilityValidated = false
    var realLoadProbeComplete = false
    var canonicalPrefixBound = false
    var wineEnvironmentReady = false

    static let total = 5

    var completedCount: Int {
        var n = 0
        if runtimeResolved { n += 1 }
        if runtimeCapabilityValidated { n += 1 }
        if realLoadProbeComplete { n += 1 }
        if canonicalPrefixBound { n += 1 }
        if wineEnvironmentReady { n += 1 }
        return n
    }

    /// Deterministic progress in [0, 1], ignoring the clock entirely.
    var progress: Double {
        Double(completedCount) / Double(Self.total)
    }
}

/// Monotonic clock source (injectable for tests).
protocol LaunchClock: Sendable {
    /// Monotonic milliseconds since an arbitrary fixed epoch.
    func nowMilliseconds() -> Int64
}

/// Monotonic production clock backed by the system uptime (never wall-clock).
struct SystemLaunchClock: LaunchClock {
    func nowMilliseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}