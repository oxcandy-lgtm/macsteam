// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - Test doubles

/// Fake GameSessionSupervising that conforms to the @MainActor protocol.
@MainActor
final class FakeGameSessionSupervisor: GameSessionSupervising {
    var state: GameSessionState = .stopped
    var activeSession: GameSession?
    var isRunning: Bool = false
    var isStopping: Bool = false
    var needsRecovery: Bool = false
    var launchCallCount = 0
    var stopCallCount = 0
    var stopError: (any Error)?
    var launchError: (any Error)?
    var lastPlan: LaunchPlan?
    var stopShouldClearActiveSession = false

    func launch(
        plan: LaunchPlan,
        runtimeControl: any WineRuntimeControl,
        prefixRoot: URL,
        recipeID: String,
        runtimeID: String,
        purpose: SessionPurpose
    ) async throws -> GameSession {
        launchCallCount += 1
        lastPlan = plan
        if let error = launchError { throw error }
        return GameSession(
            sessionID: UUID(),
            recipeID: recipeID,
            runtimeID: runtimeID,
            prefixRoot: prefixRoot,
            rootPID: 0,
            startedAt: Date(),
            purpose: purpose
        )
    }

    func stop() async throws {
        stopCallCount += 1
        if let error = stopError { throw error }
        if stopShouldClearActiveSession {
            activeSession = nil
            state = .stopped
        }
    }

    var censusResult: ProcessCensusResult = .incomplete(.noLedger)
    func processCensus() async -> ProcessCensusResult { censusResult }
}

final class FakeInstallerLifecycleSupervisor: @unchecked Sendable, InstallerLifecycleSupervising {
    var snapshotResult: InstallerOperation?
    var stopAndCleanCallCount = 0
    var stopAndCleanError: (any Error)?
    var stopKnownPrefixCallCount = 0
    var stopKnownPrefixError: (any Error)?

    func snapshot() async -> InstallerOperation? { snapshotResult }
    func stopAndClean() async throws {
        stopAndCleanCallCount += 1
        if let error = stopAndCleanError { throw error }
    }
    func stopKnownPrefixProcesses(
        wineExecutable: URL,
        wineserverURL: URL,
        prefixURL: URL,
        runtimeURL: URL
    ) async throws {
        stopKnownPrefixCallCount += 1
        if let error = stopKnownPrefixError { throw error }
    }

    // Setter helpers for cross-actor access from tests
    func setStopAndCleanError(_ error: (any Error)?) { stopAndCleanError = error }
    func setStopKnownPrefixError(_ error: (any Error)?) { stopKnownPrefixError = error }
    func setSnapshotResult(_ op: InstallerOperation?) { snapshotResult = op }
}

// MARK: - Tests

@Suite("UltimateCleanupOrchestration")
@MainActor
struct UltimateCleanupOrchestrationTests {
    let nonEmptyURL = URL(fileURLWithPath: "/tmp")
    let testRuntimeURL = URL(fileURLWithPath: "/tmp/test-runtime")
    let testPrefixURL = URL(fileURLWithPath: "/tmp/test-prefix")

    // Helper: create a coordinator with fakes
    func makeCoordinator(
        session: FakeGameSessionSupervisor = FakeGameSessionSupervisor(),
        installer: FakeInstallerLifecycleSupervisor = FakeInstallerLifecycleSupervisor()
    ) -> UltimateSetupCoordinator {
        UltimateSetupCoordinator(
            sessionSupervisor: session,
            installerSupervisor: installer
        )
    }

    // Helper: create a PrefixLayout for testing
    func makePrefixLayout(root: URL) -> PrefixLayout {
        PrefixLayout(
            root: root,
            driveC: root.appendingPathComponent("drive_c"),
            dosdevices: root.appendingPathComponent("dosdevices"),
            systemReg: root.appendingPathComponent("system.reg"),
            userReg: root.appendingPathComponent("user.reg"),
            windowsSteamCandidates: []
        )
    }

    // MARK: - Census routing via session supervisor

    @Test("coordinator census routes through the session supervisor and maps proven result")
    func coordinatorCensusRoutesThroughSupervisor() async {
        let session = FakeGameSessionSupervisor()
        session.censusResult = ProcessCensusResult(
            state: .proven,
            liveDescendants: 2,
            liveOrphans: 1,
            zombieCount: 0,
            exitedCount: 3,
            pidReuseCount: 1,
            totalLive: 3,
            error: nil
        )
        let coordinator = makeCoordinator(session: session)
        let bundle = await coordinator.generateDiagnosticBundle()
        #expect(bundle.wineProcessCensus.hostProcessProof == "proven")
        #expect(bundle.wineProcessCensus.liveDescendants == 2)
        #expect(bundle.wineProcessCensus.liveOrphans == 1)
        #expect(bundle.wineProcessCensus.exitedCount == 3)
        #expect(bundle.wineProcessCensus.pidReuseCount == 1)
        #expect(bundle.wineProcessCensus.totalLive == 3)
    }

    @Test("coordinator census fails closed when the supervisor has no ledger")
    func coordinatorCensusFailClosed() async {
        let coordinator = makeCoordinator(session: FakeGameSessionSupervisor())
        let bundle = await coordinator.generateDiagnosticBundle()
        #expect(bundle.wineProcessCensus.hostProcessProof == "notProven")
        #expect(bundle.wineProcessCensus.censusError != nil)
        #expect(bundle.wineProcessCensus.liveDescendants == 0)
        #expect(bundle.wineProcessCensus.liveOrphans == 0)
    }

    // MARK: - Cleanup orchestrator tests    @Test("all absent returns clean")
    func allAbsent_returnsClean() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // No runtime, no prefix, no active session, no installer operation
        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result == .clean)
        let stopCount = installer.stopAndCleanCallCount
        #expect(stopCount == 1)
        #expect(session.stopCallCount == 1)
        let prefixCount = installer.stopKnownPrefixCallCount
        #expect(prefixCount == 0)
    }

    @Test("all stages succeed returns clean")
    func allStagesSucceed_returnsClean() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result == .clean)
        #expect(session.stopCallCount == 1)
        let stopAndCleanCount = installer.stopAndCleanCallCount
        #expect(stopAndCleanCount == 1)
        let prefixCount = installer.stopKnownPrefixCallCount
        #expect(prefixCount == 1)
    }

    @Test("installer failure — session still attempted")
    func installerFailure_sessionStillAttempted() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        installer.stopAndCleanError = InstallerError.terminationFailed("installer busy")
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        // Give session a non-nil activeSession so it's definitely relevant
        session.activeSession = GameSession(
            sessionID: UUID(),
            recipeID: "test",
            runtimeID: "test",
            prefixRoot: testPrefixURL,
            rootPID: 42,
            startedAt: Date(),
            purpose: .steamSetup
        )

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        // Session stop is still attempted even if installer fails
        #expect(session.stopCallCount == 1)
        // Prefix cleanup is still attempted
        let prefixCount = installer.stopKnownPrefixCallCount
        #expect(prefixCount == 1)
    }

    @Test("installer failure returns incomplete")
    func installerFailure_returnsIncomplete() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        installer.stopAndCleanError = InstallerError.terminationFailed("installer busy")
        // No runtime/prefix — Stage 3 will append "Prefix cleanup context unavailable"
        // because failures is non-empty

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("Installer cleanup"))
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    @Test("session failure — prefix still attempted")
    func sessionFailure_prefixStillAttempted() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        session.stopError = SessionSupervisorError.stopFailed("session refused")
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        // Prefix cleanup is still attempted even if session stop fails
        let prefixCount = installer.stopKnownPrefixCallCount
        #expect(prefixCount == 1)
    }

    @Test("session failure returns incomplete")
    func sessionFailure_returnsIncomplete() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        session.stopError = SessionSupervisorError.stopFailed("session refused")
        // No runtime/prefix — Stage 3 will append "Prefix cleanup context unavailable"
        // because failures is non-empty

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("Session cleanup failed"))
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    @Test("prefix failure returns incomplete")
    func prefixFailure_returnsIncomplete() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        installer.setStopKnownPrefixError(InstallerError.terminationFailed("wineserver still running"))
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("Prefix cleanup"))
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    @Test("cleanup required installer — retried")
    func cleanupRequiredInstaller_retried() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // First attempt: installer throws cleanupRequired-style error
        installer.stopAndCleanError = InstallerError.terminationFailed("Prefix cleanup incomplete: wineserver still running")
        let firstResult = await coordinator.stopAllForApplicationTermination()
        #expect(firstResult != .clean)
        if case .incomplete(let reason) = firstResult {
            #expect(reason.contains("cleanup"))
        }

        // Clear the error and retry — should succeed
        installer.stopAndCleanError = nil
        let secondResult = await coordinator.stopAllForApplicationTermination()
        #expect(secondResult == .clean)
    }

    @Test("terminal interrupted installer — retried")
    func terminalInterruptedInstaller_retried() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // First attempt: installer throws interrupted-style error
        installer.stopAndCleanError = InstallerError.invalidPhaseTransition(from: .installerRunning, to: .interrupted)
        let firstResult = await coordinator.stopAllForApplicationTermination()
        #expect(firstResult != .clean)

        // Clear the error and retry — should succeed
        installer.stopAndCleanError = nil
        let secondResult = await coordinator.stopAllForApplicationTermination()
        #expect(secondResult == .clean)
    }

    @Test("active session recovery required — stopped")
    func activeSessionRecoveryRequired_stopped() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        session.needsRecovery = true
        session.state = .recoveryRequired("crash detected")
        session.activeSession = GameSession(
            sessionID: UUID(),
            recipeID: "test",
            runtimeID: "test",
            prefixRoot: testPrefixURL,
            rootPID: 42,
            startedAt: Date(),
            purpose: .game
        )
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        // stop() should be called even though the session needs recovery
        let result = await coordinator.stopAllForApplicationTermination()
        #expect(result == .clean)
        #expect(session.stopCallCount == 1)
    }

    @Test("active operation missing context — incomplete")
    func activeOperationMissingContext_incomplete() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // Simulate an active installer operation that fails
        installer.stopAndCleanError = InstallerError.terminationFailed("operation in progress")
        installer.snapshotResult = InstallerOperation(runtimeSafeID: "test", prefixSafeID: "test", phase: .installerRunning)
        // No runtimeURL or prefixLayout set — prefix cleanup cannot proceed
        // Stage 3 will append "Prefix cleanup context unavailable"

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("Installer cleanup"))
            #expect(reason.contains("Prefix cleanup context unavailable"))
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    @Test("no operation missing context — clean")
    func noOperationMissingContext_clean() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // No errors, no runtime, no prefix, no active session
        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result == .clean)
        let prefixCount = installer.stopKnownPrefixCallCount
        #expect(prefixCount == 0)
    }

    @Test("multiple failures aggregated")
    func multipleFailures_aggregated() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // All three stages fail
        installer.stopAndCleanError = InstallerError.terminationFailed("installer busy")
        session.stopError = SessionSupervisorError.stopFailed("session hung")
        installer.setStopKnownPrefixError(InstallerError.terminationFailed("wineserver busy"))
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)
        session.activeSession = GameSession(
            sessionID: UUID(),
            recipeID: "test",
            runtimeID: "test",
            prefixRoot: testPrefixURL,
            rootPID: 42,
            startedAt: Date(),
            purpose: .steamSetup
        )

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            // Verify all three failures are aggregated
            let parts = reason.components(separatedBy: "; ")
            #expect(parts.count >= 3, "Expected at least 3 failure parts, got \(parts.count): \(reason)")
            #expect(parts.contains { $0.contains("Installer cleanup") })
            #expect(parts.contains { $0.contains("Session cleanup failed") })
            #expect(parts.contains { $0.contains("Prefix cleanup") })
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    @Test("failure reason no absolute path")
    func failureReason_noAbsolutePath() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // Error with no absolute path — verify the message is preserved cleanly
        installer.stopAndCleanError = InstallerError.terminationFailed("operation in progress")
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result != .clean)
        if case .incomplete(let reason) = result {
            #expect(reason.contains("Installer cleanup"))
            // The sanitized error should not contain raw file paths
            #expect(!reason.contains("/tmp"))
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    // MARK: - Launch plan builder tests

    @Test("steam session plan has correct structure")
    func steamSessionPlan_structure() {
        let coordinator = makeCoordinator()
        let wineURL = URL(fileURLWithPath: "/usr/local/wine/bin/wine")
        let steamURL = URL(fileURLWithPath: "/prefix/drive_c/Program Files (x86)/Steam/steam.exe")
        let prefixURL = URL(fileURLWithPath: "/prefix")
        let env = ["WINEPREFIX": "/prefix", "WINEARCH": "win64"]

        let plan = coordinator.makeSteamSessionPlan(
            wineURL: wineURL,
            steamURL: steamURL,
            prefixURL: prefixURL,
            environment: env
        , renderArguments: [])

        #expect(plan.runtimeExecutable == wineURL)
        #expect(plan.arguments == [steamURL.path])
        #expect(plan.mode == .supervisedSession)
        #expect(plan.environment == env)
        #expect(plan.workingDirectory == prefixURL)
    }

    @Test("clover pit session plan has correct structure")
    func cloverPitSessionPlan_structure() {
        let coordinator = makeCoordinator()
        let wineURL = URL(fileURLWithPath: "/usr/local/wine/bin/wine")
        let steamURL = URL(fileURLWithPath: "/prefix/drive_c/Program Files (x86)/Steam/steam.exe")
        let prefixURL = URL(fileURLWithPath: "/prefix")
        let env = ["WINEPREFIX": "/prefix", "WINEARCH": "win64"]

        let plan = coordinator.makeCloverPitSessionPlan(
            wineURL: wineURL,
            steamURL: steamURL,
            prefixURL: prefixURL,
            environment: env
        , renderArguments: [])

        #expect(plan.runtimeExecutable == wineURL)
        #expect(plan.arguments == [steamURL.path, "-applaunch", "3314790", "-popupwindow", "-screen-fullscreen", "0"])
        #expect(plan.mode == .supervisedSession)
        #expect(plan.environment == env)
        #expect(plan.workingDirectory == prefixURL)
    }

    @Test("steam session plan respects empty environment")
    func steamSessionPlan_emptyEnvironment() {
        let coordinator = makeCoordinator()
        let wineURL = URL(fileURLWithPath: "/usr/local/wine/bin/wine")
        let steamURL = URL(fileURLWithPath: "/steam.exe")
        let prefixURL = URL(fileURLWithPath: "/prefix")
        let env: [String: String] = [:]

        let plan = coordinator.makeSteamSessionPlan(
            wineURL: wineURL,
            steamURL: steamURL,
            prefixURL: prefixURL,
            environment: env
        , renderArguments: [])

        #expect(plan.environment.isEmpty)
        #expect(plan.runtimeExecutable == wineURL)
    }

    @Test("clover pit session plan respects empty environment")
    func cloverPitSessionPlan_emptyEnvironment() {
        let coordinator = makeCoordinator()
        let wineURL = URL(fileURLWithPath: "/usr/local/wine/bin/wine")
        let steamURL = URL(fileURLWithPath: "/steam.exe")
        let prefixURL = URL(fileURLWithPath: "/prefix")
        let env: [String: String] = [:]

        let plan = coordinator.makeCloverPitSessionPlan(
            wineURL: wineURL,
            steamURL: steamURL,
            prefixURL: prefixURL,
            environment: env
        , renderArguments: [])

        #expect(plan.environment.isEmpty)
        #expect(plan.arguments == [steamURL.path, "-applaunch", "3314790", "-popupwindow", "-screen-fullscreen", "0"])
    }

    // MARK: - Missing context tests

    @Test("post-stop missing prefix context returns incomplete")
    func postStop_missingContext() async {
        let installer = FakeInstallerLifecycleSupervisor()
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // Session has activeSession but stop clears it AND context is missing
        session.activeSession = GameSession(
            sessionID: UUID(),
            recipeID: "test",
            runtimeID: "test",
            prefixRoot: testPrefixURL,
            rootPID: 42,
            startedAt: Date(),
            purpose: .game
        )
        session.stopShouldClearActiveSession = true
        // Missing runtime/prefix context
        coordinator.runtimeURL = nil
        coordinator.prefixLayout = nil

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(session.stopCallCount == 1)
        #expect(result == .incomplete("Prefix cleanup context unavailable"))
    }

    @Test("post-installer-cleanup missing context returns incomplete")
    func postInstaller_missingContext() async {
        let installer = FakeInstallerLifecycleSupervisor()
        installer.snapshotResult = InstallerOperation(runtimeSafeID: "test", prefixSafeID: "test", phase: .cleanupRequired)
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // Installer has snapshot but stopAndClean clears it AND context missing
        coordinator.runtimeURL = nil
        coordinator.prefixLayout = nil

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(installer.stopAndCleanCallCount == 1)
        #expect(result == .incomplete("Prefix cleanup context unavailable"))
    }

    @Test("redacted cleanup does not leak paths")
    func redactedCleanup_noPathLeaks() async {
        let installer = FakeInstallerLifecycleSupervisor()
        installer.stopAndCleanError = InstallerError.terminationFailed(
            "Failed at /Users/test/Library/Application Support/MacSteam/Prefixes/private"
        ) 
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        if case .incomplete(let reason) = result {
            #expect(!reason.contains("/Users"))
            #expect(!reason.contains("private"))
            #expect(reason.contains("Installer"))
        } else {
            Issue.record("Expected .incomplete")
        }
    }

    @Test("redacted cleanup does not leak PID")
    func redactedCleanup_noPidLeaks() async {
        let installer = FakeInstallerLifecycleSupervisor()
        installer.stopAndCleanError = InstallerError.terminationFailed(
            "Session already running (PID 4321"
        )
        let session = FakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        if case .incomplete(let reason) = result {
            #expect(!reason.contains("4321"))
            #expect(!reason.contains("PID"))
            #expect(reason.contains("Installer"))
        } else {
            Issue.record("Expected .incomplete")
        }
    }
}
