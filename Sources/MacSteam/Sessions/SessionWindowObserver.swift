// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics

struct WindowInfo: Sendable, Equatable {
    var ownerPID: Int32
    var ownerName: String
    var windowTitle: String?
    var layer: Int
    var alpha: Double
    var boundsWidth: Double
    var boundsHeight: Double
}

extension WindowInfo {
    init?(normalizing row: [String: Any]) {
        guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            pid > 0 else { return nil }
        guard let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
        guard let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue else { return nil }
        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }

        let ownerName = (row[kCGWindowOwnerName as String] as? String)?
            .precomposedStringWithCanonicalMapping ?? ""
        let windowTitle = (row[kCGWindowName as String] as? String)?
            .precomposedStringWithCanonicalMapping

        self.init(
            ownerPID: pid,
            ownerName: ownerName,
            windowTitle: windowTitle,
            layer: layer,
            alpha: alpha,
            boundsWidth: rect.width,
            boundsHeight: rect.height
        )
    }
}

enum WindowTarget: Sendable, Equatable {
    case steam
    case cloverPit
    case unsupported

    static func derive(purpose: SessionPurpose, recipeID: String) -> WindowTarget {
        switch purpose {
        case .steamInstaller, .steamSetup:
            return .steam
        case .game:
            return recipeID == "cloverpit" ? .cloverPit : .unsupported
        }
    }

    var identityKeyword: String? {
        switch self {
        case .steam: return "Steam"
        case .cloverPit: return "CloverPit"
        case .unsupported: return nil
        }
    }
}

enum WindowMatcher {
    static func isValidCandidate(_ info: WindowInfo, target: WindowTarget) -> Bool {
        guard isValidGeometry(info) else { return false }
        return hasTargetIdentity(info, target: target)
    }

    static func isValidGeometry(_ info: WindowInfo) -> Bool {
        guard info.ownerPID > 0 else { return false }
        guard info.layer == 0 else { return false }
        guard info.alpha > 0 else { return false }
        guard info.boundsWidth > 0 else { return false }
        guard info.boundsHeight > 0 else { return false }
        return true
    }

    static func hasTargetIdentity(_ info: WindowInfo, target: WindowTarget) -> Bool {
        guard let keyword = target.identityKeyword else { return false }
        return hasTargetIdentity(info, keyword: keyword)
    }

    private static func hasTargetIdentity(_ info: WindowInfo, keyword: String) -> Bool {
        if containsWord(info.ownerName, keyword) { return true }
        if let title = info.windowTitle, containsWord(title, keyword) { return true }
        return false
    }

    static func containsWord(_ haystack: String, _ keyword: String) -> Bool {
        let normalizedHaystack = haystack.precomposedStringWithCanonicalMapping.lowercased()
        let normalizedKeyword = keyword.precomposedStringWithCanonicalMapping.lowercased()
        guard !normalizedKeyword.isEmpty else { return false }

        var searchStart = normalizedHaystack.startIndex
        while let range = normalizedHaystack.range(
            of: normalizedKeyword,
            range: searchStart..<normalizedHaystack.endIndex
        ) {
            let leftIsBoundary = range.lowerBound == normalizedHaystack.startIndex
                || !isWordCharacter(normalizedHaystack[normalizedHaystack.index(before: range.lowerBound)])
            let rightIsBoundary = range.upperBound == normalizedHaystack.endIndex
                || !isWordCharacter(normalizedHaystack[range.upperBound])
            if leftIsBoundary && rightIsBoundary { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

enum WindowPhase: Sendable, Equatable {
    case unknown
    case visible
    case hidden

    var gameSessionState: GameSessionState {
        switch self {
        case .unknown: return .runningUnknown
        case .visible: return .runningVisible
        case .hidden: return .runningHidden
        }
    }
}

struct WindowReducerState: Sendable, Equatable {
    var phase: WindowPhase
    var positiveStreak: Int
    var negativeStreak: Int
    var lastProvenObservation: ContinuousClock.Instant?

    init(phase: WindowPhase = .unknown) {
        self.phase = phase
        self.positiveStreak = 0
        self.negativeStreak = 0
        self.lastProvenObservation = nil
    }
}

/// Outcome of a single observation tick.
///
/// A single observation requires BOTH `WindowInfoProviding.snapshot()`
/// success AND the R4 ownership query success. Ownership failure
/// (`.ownershipIncomplete`) is fail-closed: the previous phase is preserved.
/// Provider failure (`.windowSnapshotFailed`) is likewise fail-closed.
///
/// `.ownedMiss` means no owned window was found and no foreign candidate
/// existed. `.foreignCandidatesOnly` means foreign on-screen windows were
/// seen but none belonged to the session — a behavioral distinction for
/// diagnostics but treated as a miss for state transitions.
enum WindowObservation: Sendable, Equatable {
    case ownedPositive
    case ownedMiss
    case foreignCandidatesOnly
    case ownershipIncomplete
    case windowSnapshotFailed
    case unsupported
}

enum WindowReducer {
    static let threshold = 2

    /// Bounded duration after which a `.visible` phase degrades to
    /// `.unknown` if no proven observation has been seen.
    static let leaseDuration: Duration = .seconds(1)

    /// Reduce a single observation into the current state.
    ///
    /// - `.ownedPositive` — reset negative streak, advance positive streak,
    ///   refresh the lease. Reaches `.visible` after `threshold` strikes.
    /// - `.ownedMiss` / `.foreignCandidatesOnly` — reset positive streak,
    ///   advance negative streak, clear the lease. Reaches `.hidden` from
    ///   `.visible` only after `threshold` strikes (unknown + miss never
    ///   reaches hidden).
    /// - `.ownershipIncomplete` / `.windowSnapshotFailed` / `.unsupported`
    ///   — fail closed: state and streaks are preserved exactly.
    static func reduce(
        _ state: WindowReducerState,
        _ observation: WindowObservation,
        now: ContinuousClock.Instant
    ) -> WindowReducerState {
        var next = state
        switch observation {
        case .unsupported, .ownershipIncomplete, .windowSnapshotFailed:
            return next

        case .ownedPositive:
            next.negativeStreak = 0
            next.positiveStreak = min(next.positiveStreak + 1, threshold)
            next.lastProvenObservation = now
            if next.positiveStreak >= threshold {
                next.phase = .visible
            }

        case .ownedMiss, .foreignCandidatesOnly:
            next.positiveStreak = 0
            next.negativeStreak = min(next.negativeStreak + 1, threshold)
            if next.negativeStreak >= threshold, next.phase == .visible {
                next.phase = .hidden
            }
            // Do NOT clear lastProvenObservation: the lease measures staleness
            // since the last POSITIVE observation. Missing or fail-closed
            // observations do not reset the lease — only a new positive
            // observation refreshes it.
        }
        return next
    }

    /// Apply the bounded lease: a proven `visible` phase degrades to
    /// `unknown` when no proven observation has arrived within
    /// `leaseDuration`. A phase that is already `unknown` or `hidden` is
    /// not affected by lease expiry.
    static func applyLease(
        _ state: WindowReducerState,
        now: ContinuousClock.Instant
    ) -> WindowReducerState {
        var next = state
        if next.phase == .visible {
            let expired: Bool
            if let last = next.lastProvenObservation {
                expired = now > last + leaseDuration
            } else {
                expired = true
            }
            if expired {
                next.phase = .unknown
            }
        }
        return next
    }
}

enum WindowObserverError: Error, Sendable {
    case snapshotFailed
}

protocol WindowInfoProviding: Sendable {
    func snapshot() throws -> [WindowInfo]
}

struct WindowServerProvider: WindowInfoProviding {
    func snapshot() throws -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw WindowObserverError.snapshotFailed
        }
        return raw.compactMap { WindowInfo(normalizing: $0) }
    }
}

/// A token that uniquely identifies a monitor lifecycle instance.
///
/// Stamps observations with a session ID + generation so that a stale
/// monitor (from a superseded session or an invalidated lifecycle)
/// cannot apply state to the wrong session or survive a rollback.
struct MonitorLease: Hashable, Sendable {
    let sessionID: UUID
    let generation: UInt64
}

/// Observes on-screen window presence for a single supervised session and
/// drives `GameSessionState` visibility.
///
/// **U1R18-R3:** Every observation is ownership-bound. A window is reported
/// visible only when BOTH:
/// 1. `WindowInfoProviding.snapshot()` succeeds and a valid on-screen window is found, AND
/// 2. the ownership closure returns a non-nil set containing that window's owner PID.
///
/// The ownership closure is supplied by `GameSessionSupervisor` and delegates
/// to the R4 authority (`HostProcessLineage.ownedProcessIDs`). No parallel
/// process-tree authority exists.
@MainActor
final class SessionWindowObserver {
    private let provider: any WindowInfoProviding

    /// Ownership query: returns the set of PIDs proven to belong to the
    /// supervised session, or `nil` when ownership cannot be proven
    /// (fail-closed). When `nil`, the observer falls back to keyword-only
    /// matching for unscoped detection.
    private var ownershipSnapshot: (@MainActor () async -> Set<Int32>?)?

    private var monitorTask: Task<Void, Never>?
    private var reducerState = WindowReducerState()
    private var activeTarget: WindowTarget = .unsupported
    private var applyState: (@MainActor (GameSessionState) -> Void)?
    private(set) var generation: UInt64 = 0
    private(set) var activeSessionID: UUID?

    init(provider: any WindowInfoProviding = WindowServerProvider()) {
        self.provider = provider
    }

    var isMonitoring: Bool {
        guard let task = monitorTask else { return false }
        return !task.isCancelled
    }

    /// The current lease for test-driven `tickOnce` calls. Returns `nil`
    /// when no monitor is active.
    var currentLease: MonitorLease? {
        guard let sessionID = activeSessionID else { return nil }
        return MonitorLease(sessionID: sessionID, generation: generation)
    }

    /// Start (or restart) window observation for a session.
    ///
    /// - Parameters:
    ///   - sessionID: identity of the session this monitor serves.
    ///   - target: window target keyword (used only for unscoped fallback).
    ///   - ownershipSnapshot: R4 ownership closure; `nil` falls back to
    ///     keyword-only matching.
    ///   - pollInterval: time between observation ticks.
    ///   - applyState: callback invoked with the derived `GameSessionState`.
    func startMonitoring(
        sessionID: UUID,
        target: WindowTarget,
        ownershipSnapshot: (@MainActor () async -> Set<Int32>?)? = nil,
        pollInterval: Duration = .milliseconds(300),
        applyState: @escaping @MainActor (GameSessionState) -> Void
    ) {
        invalidate()
        generation &+= 1
        activeSessionID = sessionID
        activeTarget = target
        self.ownershipSnapshot = ownershipSnapshot
        self.applyState = applyState
        reducerState = WindowReducerState()
        let capturedLease = MonitorLease(sessionID: sessionID, generation: generation)

        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.tickOnce(lease: capturedLease)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Perform a single observation tick if the lease is still valid.
    func tickOnce(lease: MonitorLease?) async {
        guard let lease else { return }
        let sessionID = activeSessionID
        let gen = generation
        guard sessionID == lease.sessionID, gen == lease.generation else { return }

        let now = ContinuousClock.now
        let observation = await observe(
            target: activeTarget,
            ownershipSnapshot: ownershipSnapshot
        )
        reducerState = WindowReducer.reduce(reducerState, observation, now: now)
        reducerState = WindowReducer.applyLease(reducerState, now: now)

        guard activeSessionID == lease.sessionID, generation == lease.generation,
              !Task.isCancelled else { return }
        applyState?(reducerState.phase.gameSessionState)
    }

    /// Invalidate the running monitor, clearing all session-scoped state.
    ///
    /// Called on every lifecycle event (launch-start, launch-rollback,
    /// normal-stop, force-stop, cleanup-tx, recovery-cleanup,
    /// session-replacement, terminal-stopped, failed-launch) so a stale
    /// monitor from a previous or failed session can never apply state.
    func invalidate() {
        generation &+= 1
        activeSessionID = nil
        ownershipSnapshot = nil
        applyState = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Perform a single observation, requiring BOTH the window snapshot
    /// and the ownership query to succeed.
    ///
    /// - Ownership present → session-scoped: a candidate is valid only if
    ///   its owner PID is in the ownership set.
    /// - Ownership absent (closure is `nil`) → unscoped keyword matching.
    /// - Ownership returns `nil` → `.ownershipIncomplete` (fail-closed).
    /// - Provider throws → `.windowSnapshotFailed` (fail-closed).
    private func observe(
        target: WindowTarget,
        ownershipSnapshot: (@MainActor () async -> Set<Int32>?)?
    ) async -> WindowObservation {
        guard target != .unsupported else { return .unsupported }

        let windows: [WindowInfo]
        do {
            windows = try provider.snapshot()
        } catch {
            return .windowSnapshotFailed
        }

        if let ownershipSnapshot {
            guard let owned = await ownershipSnapshot() else {
                return .ownershipIncomplete
            }
            let validWindows = windows.filter { WindowMatcher.isValidGeometry($0) }
            let hasOwned = validWindows.contains { owned.contains($0.ownerPID) }
            if hasOwned {
                return .ownedPositive
            }
            return validWindows.isEmpty ? .ownedMiss : .foreignCandidatesOnly
        } else {
            let hit = windows.contains { WindowMatcher.isValidGeometry($0) }
            return hit ? .ownedPositive : .ownedMiss
        }
    }
}
