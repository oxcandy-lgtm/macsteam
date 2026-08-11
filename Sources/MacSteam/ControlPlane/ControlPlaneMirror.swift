// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MacsTeamControlPlane

/// U1R18-R13-ACCEPTANCE4-STATE-MIRROR: the production control-plane mirror.
///
/// A light (250 ms) loop on the MainActor projects the coordinator's CURRENT
/// state into a ``ControlPlaneSnapshot``. `state.json` is atomically replaced
/// ONLY when the projected content actually changed; `events.ndjson` is the
/// append-only structured event stream.
///
/// No IPC, no screenshot proof, no new state machine: every flag is the
/// production supervisor/coordinator's already-observed state.
@MainActor
final class ControlPlaneMirror {
    private let coordinator: UltimateSetupCoordinator
    private let store = ControlPlaneStore()

    private var task: Task<Void, Never>?
    private var previousSnapshot: ControlPlaneSnapshot?
    private var previousInstallerLogLength = 0
    private var didEmitAppStarted = false

    init(coordinator: UltimateSetupCoordinator) {
        self.coordinator = coordinator
    }

    /// Start the mirror loop. Idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop the mirror loop. Idempotent.
    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func tick() async {
        let snapshot = await coordinator.controlPlaneSnapshot()

        // First tick doubles as the authoritative app_started record: it carries
        // the REAL first observed screen/state, never a nil placeholder.
        if !didEmitAppStarted {
            didEmitAppStarted = true
            let event = ControlPlaneEvent(
                event: "app_started",
                ts: Date().timeIntervalSince1970,
                screen: snapshot.screen,
                setup_state: snapshot.setup_state
            )
            try? store.appendEvent(event)
        }

        let events = diffEvents(previous: previousSnapshot, current: snapshot)
        let newLogEvents = installerLogEvents()

        var didChange = snapshot != previousSnapshot

        for event in events {
            try? store.appendEvent(event)
        }
        for event in newLogEvents {
            try? store.appendEvent(event)
        }

        // Installer log growth also changes the projected message, so reflect
        // it in state.json even if nothing else moved.
        if !newLogEvents.isEmpty {
            didChange = true
        }

        if didChange {
            try? store.writeSnapshot(snapshot)
        }

        previousSnapshot = snapshot
    }

    // MARK: - Events

    /// Diff the previous and current snapshots into structured events.
    private func diffEvents(
        previous: ControlPlaneSnapshot?,
        current: ControlPlaneSnapshot
    ) -> [ControlPlaneEvent] {
        guard let previous else {
            // First tick: nothing to diff beyond app_started.
            return []
        }

        let now = Date().timeIntervalSince1970
        var events: [ControlPlaneEvent] = []

        func base(_ name: String) -> ControlPlaneEvent {
            ControlPlaneEvent(
                event: name,
                ts: now,
                screen: current.screen,
                setup_state: current.setup_state
            )
        }

        if previous.screen != current.screen {
            var e = base("screen_changed")
            e.from = previous.screen
            e.to = current.screen
            events.append(e)
        }

        if previous.setup_state != current.setup_state {
            var e = base("setup_state_changed")
            e.from = previous.setup_state
            e.to = current.setup_state
            events.append(e)
        }

        if previous.actions != current.actions {
            events.append(base("action_availability_changed"))
        }

        if previous.runtime != current.runtime {
            events.append(base("runtime_changed"))
        }

        if previous.prefix != current.prefix {
            events.append(base("prefix_changed"))
        }

        if previous.steam != current.steam {
            events.append(base("steam_state_changed"))
        }
        if previous.steam.window_visible != current.steam.window_visible {
            events.append(base(current.steam.window_visible ? "steam_window_visible" : "steam_window_hidden"))
        }

        if previous.cloverpit != current.cloverpit {
            events.append(base("cloverpit_state_changed"))
        }
        if previous.cloverpit.window_visible != current.cloverpit.window_visible {
            events.append(base(current.cloverpit.window_visible ? "cloverpit_window_visible" : "cloverpit_window_hidden"))
        }

        if previous.last_transition != current.last_transition,
           let transition = current.last_transition {
            var e = base(transition.accepted ? "navigation_accepted" : "navigation_rejected")
            e.from = transition.from
            e.to = transition.to
            e.action = transition.action
            e.accepted = transition.accepted
            events.append(e)
        }

        if previous.last_error != current.last_error {
            var e = base("error_changed")
            e.error = current.last_error
            events.append(e)
        }

        return events
    }

    /// Emit `installer_message` for every NEW line appended to the coordinator
    /// installer log since the last tick (bounded: never re-emits history).
    private func installerLogEvents() -> [ControlPlaneEvent] {
        let log = coordinator.installerLog
        let currentLength = log.utf8.count
        guard currentLength > previousInstallerLogLength else {
            previousInstallerLogLength = currentLength
            return []
        }

        let newChunk = String(log.dropFirst(previousInstallerLogLength))
        previousInstallerLogLength = currentLength

        let now = Date().timeIntervalSince1970
        let lines = newChunk.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.map { line in
            ControlPlaneEvent(
                event: "installer_message",
                ts: now,
                screen: coordinator.currentPage.rawValue,
                setup_state: coordinator.state.rawValue,
                message: String(line.prefix(200))
            )
        }
    }
}
