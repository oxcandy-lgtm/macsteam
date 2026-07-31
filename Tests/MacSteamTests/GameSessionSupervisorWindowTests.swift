// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

private struct FalseWineserverRuntime: WineRuntimeControl {
    var wineserverExecutable: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        ["WINEPREFIX": prefix.path]
    }
}

private func makeTempPrefix() throws -> URL {
    let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
    let dir = root.appendingPathComponent("ms-u1r18-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return dir
}

private func cloverPitWindow() -> WindowInfo {
    WindowInfo(
        ownerPID: 4242,
        ownerName: "CloverPit",
        windowTitle: "CloverPit",
        layer: 0,
        alpha: 1.0,
        boundsWidth: 1280,
        boundsHeight: 720
    )
}

@MainActor
private func waitForState(
    _ supervisor: GameSessionSupervisor,
    _ target: GameSessionState,
    timeout: Duration = .seconds(4)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if supervisor.state == target { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return supervisor.state == target
}

struct GameSessionSupervisorWindowTests {

    @Test("isRunning holds across unknown, visible, and hidden") @MainActor
    func isRunningAcrossWindowStates() async throws {
        let provider = MockWindowProvider()
        let supervisor = GameSessionSupervisor(windowProvider: provider)
        let prefixDir = try makeTempPrefix()
        defer {
            SessionReceiptStore().remove(prefix: prefixDir)
            try? FileManager.default.removeItem(at: prefixDir)
        }

        let plan = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            mode: .supervisedSession
        )
        _ = try await supervisor.launch(
            plan: plan,
            runtimeControl: FalseWineserverRuntime(),
            prefixRoot: prefixDir,
            recipeID: "cloverpit",
            runtimeID: "test",
            purpose: .game
        )

        #expect(supervisor.state == .runningUnknown)
        #expect(supervisor.isRunning)
        #expect(supervisor.isWindowMonitoring)

        provider.windows = [cloverPitWindow()]
        #expect(await waitForState(supervisor, .runningVisible))
        #expect(supervisor.isRunning)

        provider.windows = []
        #expect(await waitForState(supervisor, .runningHidden))
        #expect(supervisor.isRunning)

        try? await supervisor.forceStop()
    }

    @Test("launch starts exactly one monitor; stop invalidates it") @MainActor
    func launchStartsMonitorAndStopInvalidates() async throws {
        let provider = MockWindowProvider()
        let supervisor = GameSessionSupervisor(windowProvider: provider)
        let prefixDir = try makeTempPrefix()
        defer {
            SessionReceiptStore().remove(prefix: prefixDir)
            try? FileManager.default.removeItem(at: prefixDir)
        }

        #expect(!supervisor.isWindowMonitoring)

        let plan = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["1"],
            mode: .supervisedSession
        )
        _ = try await supervisor.launch(
            plan: plan,
            runtimeControl: FalseWineserverRuntime(),
            prefixRoot: prefixDir,
            recipeID: "cloverpit",
            runtimeID: "test",
            purpose: .game
        )
        #expect(supervisor.isWindowMonitoring)

        try? await Task.sleep(for: .milliseconds(1400))
        try? await supervisor.stop()
        #expect(!supervisor.isWindowMonitoring)
    }

    @Test("failed launch leaves no monitor and resets to idle") @MainActor
    func failedLaunchCleanup() async throws {
        let provider = MockWindowProvider()
        let supervisor = GameSessionSupervisor(windowProvider: provider)
        let prefixDir = try makeTempPrefix()
        defer {
            SessionReceiptStore().remove(prefix: prefixDir)
            try? FileManager.default.removeItem(at: prefixDir)
        }

        let badPlan = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/nonexistent/binary-\(UUID().uuidString)"),
            arguments: [],
            mode: .supervisedSession
        )
        do {
            _ = try await supervisor.launch(
                plan: badPlan,
                runtimeControl: FalseWineserverRuntime(),
                prefixRoot: prefixDir,
                recipeID: "cloverpit",
                runtimeID: "test",
                purpose: .game
            )
            #expect(Bool(false), "Expected launch failure")
        } catch {
            // expected
        }

        #expect(supervisor.state == .idle)
        #expect(!supervisor.isWindowMonitoring)
    }

    @Test("production manual visibility authority is zero")
    func manualVisibilityAuthorityRemoved() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacSteam/Sessions/GameSessionSupervisor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("confirmWindowVisible"))
        #expect(!source.contains("reportWindowHidden"))
    }

    @Test("visibility is observation-driven, not spontaneous") @MainActor
    func visibilityObservationDriven() async throws {
        let provider = MockWindowProvider()
        let supervisor = GameSessionSupervisor(windowProvider: provider)
        let prefixDir = try makeTempPrefix()
        defer {
            SessionReceiptStore().remove(prefix: prefixDir)
            try? FileManager.default.removeItem(at: prefixDir)
        }

        let plan = LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["3"],
            mode: .supervisedSession
        )
        _ = try await supervisor.launch(
            plan: plan,
            runtimeControl: FalseWineserverRuntime(),
            prefixRoot: prefixDir,
            recipeID: "cloverpit",
            runtimeID: "test",
            purpose: .game
        )

        try? await Task.sleep(for: .milliseconds(800))
        #expect(supervisor.state == .runningUnknown)

        try? await supervisor.forceStop()
    }
}
