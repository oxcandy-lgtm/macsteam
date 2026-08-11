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

/// Result of an attempted launch-stage transition (U1R18-R13-FIX1-FIX1 §3.1).
enum LaunchTransitionResult: Equatable, Sendable {
    case admitted
    case rejectedSkipped
    case rejectedBackward
    case rejectedSame
}

/// Single production launch transition + telemetry authority.
///
/// This is the ONLY place the coordinator may advance the launch stage, earn a
/// Wine milestone, or record a timing segment. Arbitrary call sites cannot
/// freely assign stage values. The authority:
///   - begins a new timing attempt deterministically,
///   - admits only explicit allowed transitions (an explicit graph, NEVER enum
///     numeric adjacency),
///   - rejects illegal/out-of-order transitions (preserving the prior valid
///     stage),
///   - exposes failure explicitly,
///   - separates identity-bound validation evidence (Wine milestones) from the
///     per-attempt timing, so a new Steam timing attempt does not erase still
///     current validated evidence,
///   - never derives progress from a fake timer.
struct LaunchTransitionAuthority: Sendable {
    private(set) var stage: LaunchPipelineStage = .idle
    private(set) var wineMilestones = WineMilestones()
    private(set) var timing = LaunchTiming()
    private(set) var failed = false

    init() {}

    /// Explicit allowed-transition graph. Enum numeric adjacency is NOT
    /// workflow authority; only these edges are legal. `.failed` may be entered
    /// from any active stage (handled separately).
    static let allowedTransitions: [LaunchPipelineStage: Set<LaunchPipelineStage>] = [
        .idle: [.validatingRuntime, .startingSteam],
        .validatingRuntime: [.probingWine],
        .probingWine: [.resolvingPrefix],
        .resolvingPrefix: [.validatingSteam],
        .validatingSteam: [.preparingWine],
        .preparingWine: [.startingSteam],
        .startingSteam: [.waitingForSteam],
        .waitingForSteam: [.ready, .launchingCloverPit],
        .launchingCloverPit: [.waitingForCloverPit],
        .waitingForCloverPit: [.ready],
        .ready: [],
        .failed: [],
    ]

    /// Full reset: clears stage, timing, failure flag, and ALL validation
    /// evidence. Used only for a brand-new validation.
    mutating func reset() {
        stage = .idle
        wineMilestones = WineMilestones()
        timing = LaunchTiming()
        failed = false
    }

    /// Begin a new Steam timing attempt. Resets stage/timing/failure but
    /// PRESERVES still-current identity-bound Wine evidence (FIX C). Identity
    /// changes must clear the corresponding milestone separately.
    mutating func beginSteamAttempt() {
        stage = .idle
        timing = LaunchTiming()
        failed = false
    }

    /// Clear a single validation-evidence milestone (called on identity
    /// change so stale evidence is never carried across a runtime/prefix/Steam
    /// change).
    mutating func clearMilestone(_ key: WineMilestoneKey) {
        guard !failed else { return }
        switch key {
        case .runtimeResolved: wineMilestones.runtimeResolved = false
        case .runtimeCapabilityValidated: wineMilestones.runtimeCapabilityValidated = false
        case .realLoadProbeComplete: wineMilestones.realLoadProbeComplete = false
        case .canonicalPrefixBound: wineMilestones.canonicalPrefixBound = false
        case .wineEnvironmentReady: wineMilestones.wineEnvironmentReady = false
        }
    }

    /// Advance through the explicit transition graph. Illegal/out-of-order
    /// transitions are rejected and the prior valid stage is preserved.
    @discardableResult
    mutating func transition(to next: LaunchPipelineStage) -> LaunchTransitionResult {
        guard !failed else {
            return next == .failed ? .rejectedSame : .rejectedSkipped
        }
        if next == .failed {
            stage = .failed
            failed = true
            return .admitted
        }
        if next == stage { return .rejectedSame }
        guard let allowed = Self.allowedTransitions[stage], allowed.contains(next) else {
            return next.rawValue < stage.rawValue ? .rejectedBackward : .rejectedSkipped
        }
        stage = next
        return .admitted
    }

    /// Earn a Wine milestone from real production evidence. Never optimistic.
    mutating func earn(_ key: WineMilestoneKey) {
        guard !failed else { return }
        switch key {
        case .runtimeResolved: wineMilestones.runtimeResolved = true
        case .runtimeCapabilityValidated: wineMilestones.runtimeCapabilityValidated = true
        case .realLoadProbeComplete: wineMilestones.realLoadProbeComplete = true
        case .canonicalPrefixBound: wineMilestones.canonicalPrefixBound = true
        case .wineEnvironmentReady: wineMilestones.wineEnvironmentReady = true
        }
    }

    /// Record a timing segment duration (monotonic, never negative).
    mutating func record(_ segment: LaunchTimingSegment, milliseconds ms: Int64) {
        guard !failed else { return }
        timing.record(segment, milliseconds: max(0, ms))
    }

    /// Mark the attempt failed: exposes failure explicitly and clears stale
    /// success timing, but preserves identity-bound Wine evidence (FIX C).
    mutating func fail() {
        failed = true
        stage = .failed
        timing = LaunchTiming()
    }

    var progress: Double { wineMilestones.progress }
}

/// Named Wine milestone keys (U1R18-R13-FIX1 §5.1).
enum WineMilestoneKey: Sendable {
    case runtimeResolved
    case runtimeCapabilityValidated
    case realLoadProbeComplete
    case canonicalPrefixBound
    case wineEnvironmentReady
}

/// Named timing segments (U1R18-R13-FIX1 §6).
enum LaunchTimingSegment: Sendable {
    case winePreparation
    case steamProcessStart
    case steamReady
}