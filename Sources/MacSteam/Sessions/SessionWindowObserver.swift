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
        guard let keyword = target.identityKeyword else { return false }
        guard info.ownerPID > 0 else { return false }
        guard info.layer == 0 else { return false }
        guard info.alpha > 0 else { return false }
        guard info.boundsWidth > 0 else { return false }
        guard info.boundsHeight > 0 else { return false }
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

    init(phase: WindowPhase = .unknown) {
        self.phase = phase
        self.positiveStreak = 0
        self.negativeStreak = 0
    }
}

enum WindowObservation: Sendable, Equatable {
    case positive
    case miss
    case error
    case unsupported
}

enum WindowReducer {
    static let threshold = 2

    static func reduce(
        _ state: WindowReducerState,
        _ observation: WindowObservation
    ) -> WindowReducerState {
        var next = state
        switch observation {
        case .error, .unsupported:
            return next
        case .positive:
            next.negativeStreak = 0
            next.positiveStreak = min(next.positiveStreak + 1, threshold)
            if next.positiveStreak >= threshold {
                next.phase = .visible
            }
        case .miss:
            next.positiveStreak = 0
            next.negativeStreak = min(next.negativeStreak + 1, threshold)
            if next.negativeStreak >= threshold, next.phase == .visible {
                next.phase = .hidden
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

@MainActor
final class SessionWindowObserver {
    private let provider: any WindowInfoProviding
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

    func startMonitoring(
        sessionID: UUID,
        target: WindowTarget,
        pollInterval: Duration = .milliseconds(300),
        applyState: @escaping @MainActor (GameSessionState) -> Void
    ) {
        invalidate()
        generation &+= 1
        activeSessionID = sessionID
        activeTarget = target
        self.applyState = applyState
        reducerState = WindowReducerState()
        let capturedGeneration = generation

        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                self.tickOnce(generation: capturedGeneration)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func tickOnce(generation capturedGeneration: UInt64) {
        guard capturedGeneration == generation else { return }
        let observation = Self.observe(provider: provider, target: activeTarget)
        reducerState = WindowReducer.reduce(reducerState, observation)
        guard capturedGeneration == generation, !Task.isCancelled else { return }
        applyState?(reducerState.phase.gameSessionState)
    }

    func invalidate() {
        generation &+= 1
        activeSessionID = nil
        applyState = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    private static func observe(
        provider: any WindowInfoProviding,
        target: WindowTarget
    ) -> WindowObservation {
        guard target != .unsupported else { return .unsupported }
        do {
            let windows = try provider.snapshot()
            let hit = windows.contains { WindowMatcher.isValidCandidate($0, target: target) }
            return hit ? .positive : .miss
        } catch {
            return .error
        }
    }
}
