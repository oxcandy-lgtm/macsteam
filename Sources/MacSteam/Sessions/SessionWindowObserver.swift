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

/// A single observation requires BOTH `WindowInfoProviding.snapshot()` success
/// AND the R4 ownership query success.
///
/// - `.ownedPositive` — a target-matching window exists whose owner PID is in
///   the R4-proven ownership set.
/// - `.ownedMiss` — window snapshot and ownership both succeeded, but no
///   target-matching on-screen window exists.
/// - `.foreignCandidatesOnly` — target-matching on-screen windows exist but
///   none are owned by the session (foreign target candidates seen).
/// - `.ownershipIncomplete` — window snapshot succeeded but the R4 ownership
///   query returned `nil` (fail-closed: state preserved).
/// - `.windowSnapshotFailed` — the window snapshot provider threw (fail-closed).
/// - `.unsupported` — the target keyword is nil (no identity to match).
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
    /// `.unknown` if no proven positive observation has been seen.
    static let leaseDuration: Duration = .seconds(1)

    /// Reduce a single observation into the current state.
    ///
    /// - `.ownedPositive` — reset negative streak, advance positive streak,
    ///   refresh the lease. Reaches `.visible` after `threshold` strikes.
    /// - `.ownedMiss` / `.foreignCandidatesOnly` — reset positive streak,
    ///   advance negative streak. Reaches `.hidden` from `.visible` only
    ///   after `threshold` strikes; `unknown + miss` never reaches hidden.
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
        }
        return next
    }

    /// Apply the bounded lease: a proven `visible` phase degrades to
    /// `unknown` when no positive observation has arrived within
    /// `leaseDuration`. `unknown` and `hidden` are unaffected.
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

/// R4 ownership query type. Non-optional: every observation requires it.
/// Returns `nil` → `.ownershipIncomplete` (fail-closed).
typealias WindowOwnershipSnapshot = @MainActor () async -> Set<Int32>?

/// A token that uniquely identifies a monitor lifecycle instance.
///
/// Stamps observations with a session ID + generation so that a stale
/// monitor (from a superseded session or an invalidated lifecycle) cannot
/// apply state to the wrong session or survive a rollback.
struct MonitorLease: Hashable, Sendable {
    let sessionID: UUID
    let generation: UInt64
}

/// Observes on-screen window presence for a single supervised session and
/// drives `GameSessionState` visibility.
///
/// **U1R18-R3:** Every observation is ownership-bound. A window is reported
/// visible only when BOTH:
/// 1. `WindowInfoProviding.snapshot()` succeeds, AND
/// 2. the R4 ownership closure returns a non-nil set, AND
/// 3. a target-identity-matching window owns a PID in that set.
///
/// The ownership closure is supplied by `GameSessionSupervisor` and delegates
/// to `GameSessionSupervisor.ownedProcessSnapshot()` →
/// `HostProcessLineage.ownedProcessIDs(ledger:)`. No parallel process-tree
/// authority exists. Unscoped / keyword-only / geometry-only fallbacks are
/// explicitly prohibited.
@MainActor
final class SessionWindowObserver {
    private let provider: any WindowInfoProviding

    /// R4 ownership query: returns the set of PIDs proven to belong to the
    /// supervised session, or `nil` when ownership cannot be proven
    /// (fail-closed). Non-optional — every observation requires it.
    private var ownershipSnapshot: WindowOwnershipSnapshot

    private var monitorTask: Task<Void, Never>?
    private var reducerState = WindowReducerState()
    private var activeTarget: WindowTarget = .unsupported
    private var applyState: (@MainActor (GameSessionState) -> Void)?
    private(set) var generation: UInt64 = 0
    private(set) var activeSessionID: UUID?

    init(provider: any WindowInfoProviding = WindowServerProvider()) {
        self.provider = provider
        self.ownershipSnapshot = { nil }
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
    ///   - target: window target keyword (Steam / CloverPit).
    ///   - ownershipSnapshot: **required** R4 ownership closure; returns the
    ///     set of proven-owned PIDs, or `nil` for fail-closed.
    ///   - pollInterval: time between observation ticks.
    ///   - applyState: callback invoked with the derived `GameSessionState`.
    func startMonitoring(
        sessionID: UUID,
        target: WindowTarget,
        ownershipSnapshot: @escaping WindowOwnershipSnapshot,
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
        ownershipSnapshot = { nil }
        applyState = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Perform a single observation, requiring BOTH the window snapshot
    /// AND the R4 ownership query to succeed.
    ///
    /// - `ownedPositive`: a target-matching window whose owner PID is in the
    ///   ownership set.
    /// - `foreignCandidatesOnly`: target-matching windows exist but none are owned.
    /// - `ownedMiss`: no target-matching windows at all.
    /// - `ownershipIncomplete`: ownership closure returned `nil` (fail-closed).
    /// - `windowSnapshotFailed`: provider threw (fail-closed).
    /// - `unsupported`: target keyword is nil.
    private func observe(
        target: WindowTarget,
        ownershipSnapshot: WindowOwnershipSnapshot
    ) async -> WindowObservation {
        guard target != .unsupported else { return .unsupported }

        let windows: [WindowInfo]
        do {
            windows = try provider.snapshot()
        } catch {
            return .windowSnapshotFailed
        }

        guard let owned = await ownershipSnapshot() else {
            return .ownershipIncomplete
        }

        let targetCandidates = windows.filter {
            WindowMatcher.isValidCandidate($0, target: target)
        }

        if targetCandidates.contains(where: { owned.contains($0.ownerPID) }) {
            return .ownedPositive
        }

        if !targetCandidates.isEmpty {
            return .foreignCandidatesOnly
        }

        return .ownedMiss
    }
}
