// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Allowed phase transitions
// ---------------------------------------------------------------------------

/// A dictionary mapping every ``InstallerPhase`` to the set of phases it may
/// legally transition to.
///
/// Terminal states (``InstallerPhase/isTerminal``) may only transition back to
/// ``idle`` (or to another terminal state such as ``cleanupRequired`` or
/// ``failed``). All other states follow a forward-progress DAG.
let InstallerPhaseAllowedTransitions: [InstallerPhase: Set<InstallerPhase>] = [
    // ── Inactive ──────────────────────────────────────────────────────────
    .idle: [.preflightCleaning, .failed, .interrupted],

    // ── Pre-flight ────────────────────────────────────────────────────────
    .preflightCleaning:  [.prefixPreparing, .interrupted, .cleanupRequired, .failed],
    .prefixPreparing:    [.installerLaunching, .interrupted, .cleanupRequired, .failed],

    // ── Installer process ─────────────────────────────────────────────────
    .installerLaunching: [.installerRunning, .interrupted, .cleanupRequired, .failed],
    .installerRunning:   [.installerExited, .interrupted, .cleanupRequired, .failed],
    .installerExited:    [.verifyingInstallation, .steamBootstrapDetected, .interrupted, .cleanupRequired, .failed],

    // ── Bootstrap ─────────────────────────────────────────────────────────
    .steamBootstrapDetected: [.bootstrapStopping, .interrupted, .cleanupRequired, .failed],
    .bootstrapStopping:      [.verifyingInstallation, .interrupted, .cleanupRequired, .failed],

    // ── Verification ──────────────────────────────────────────────────────
    .verifyingInstallation: [.steamReady, .interrupted, .cleanupRequired, .failed],

    // ── Steam ready / runtime ─────────────────────────────────────────────
    .steamReady:    [.steamLaunching, .stopping, .interrupted, .cleanupRequired, .failed],
    .steamLaunching: [.steamVisible, .steamHidden, .interrupted, .cleanupRequired, .failed],
    .steamVisible:   [.steamHidden, .stopping, .interrupted, .cleanupRequired, .failed],
    .steamHidden:    [.steamVisible, .stopping, .interrupted, .cleanupRequired, .failed],

    // ── Stopping ──────────────────────────────────────────────────────────
    .stopping: [.steamReady, .interrupted, .cleanupRequired, .failed],

    // ── Terminal / recovery ───────────────────────────────────────────────
    .interrupted:     [.idle, .cleanupRequired, .failed],
    .cleanupRequired: [.idle, .failed],
    .failed:          [.idle],
]

// ---------------------------------------------------------------------------
// MARK: - Error type
// ---------------------------------------------------------------------------

/// Errors that can occur during Steam installation lifecycle management.
enum InstallerError: Error, LocalizedError {
    /// The requested phase transition is not allowed by the state machine.
    case invalidPhaseTransition(from: InstallerPhase, to: InstallerPhase)
    /// No Wine runtime has been configured for this operation.
    case runtimeNotConfigured
    /// No Wine prefix has been configured for this operation.
    case prefixNotConfigured
    /// The installer executable could not be found on disk.
    case installerNotFound
    /// The environment is not in a valid state for installation.
    case invalidEnvironment
    /// The installer or bootstrap process could not be terminated.
    case terminationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPhaseTransition(from, to):
            return "Invalid phase transition: \(from.rawValue) → \(to.rawValue)"
        case .runtimeNotConfigured:
            return "Wine runtime has not been configured"
        case .prefixNotConfigured:
            return "Wine prefix has not been configured"
        case .installerNotFound:
            return "Installer executable not found"
        case .invalidEnvironment:
            return "The installation environment is invalid"
        case let .terminationFailed(reason):
            return "Failed to terminate process: \(reason)"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Operation model
// ---------------------------------------------------------------------------

/// A single Steam installation operation, tracking its lifecycle phase and
/// associated runtime / prefix identifiers.
///
/// Use ``transition(to:)`` to advance the operation's phase; it validates
/// every transition against ``InstallerPhaseAllowedTransitions`` and throws
/// ``InstallerError/invalidPhaseTransition(from:to:)`` on illegal moves.
struct InstallerOperation: Sendable {
    // ── Identity ──────────────────────────────────────────────────────────
    let id: UUID
    let runtimeSafeID: String
    let prefixSafeID: String

    // ── Lifecycle ─────────────────────────────────────────────────────────
    var phase: InstallerPhase
    let startedAt: Date
    var updatedAt: Date
    var lastError: String?

    // ── Initialiser ───────────────────────────────────────────────────────

    /// Creates a new operation in the ``InstallerPhase/idle`` phase.
    init(
        id: UUID = UUID(),
        runtimeSafeID: String,
        prefixSafeID: String,
        phase: InstallerPhase = .idle,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.id = id
        self.runtimeSafeID = runtimeSafeID
        self.prefixSafeID = prefixSafeID
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }

    // ── Phase transitions ─────────────────────────────────────────────────

    /// Attempt to transition to `newPhase`.
    ///
    /// - Parameter newPhase: The target phase to move into.
    /// - Throws: ``InstallerError/invalidPhaseTransition(from:to:)`` if the
    ///   move is not allowed by the transition table.
    mutating func transition(to newPhase: InstallerPhase) throws {
        guard let allowed = InstallerPhaseAllowedTransitions[phase],
              allowed.contains(newPhase)
        else {
            throw InstallerError.invalidPhaseTransition(
                from: phase,
                to: newPhase
            )
        }
        phase = newPhase
        updatedAt = Date()
    }
}
