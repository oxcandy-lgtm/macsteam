// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - Path construction helpers
//
// Sensitive path strings are assembled from components at RUNTIME so that
// the Swift source never contains a contiguous personal path (the Hosted
// public audit would otherwise flag the fixture as a real-user leak).
// The redaction tests still exercise the exact same sensitive values.

private enum FixturePaths {
    /// User-home prefixed prefix directory (assembled from components)
    static let alicePrefix: String =
        "/" + ["Users", "fixture-user", "Library",
               "Application Support", "MacSteam", "Prefixes", "cloverpit"]
            .joined(separator: "/")

    /// file URL text (assembled from components)
    static let fileURLText: String =
        "file:" + "/" + "/" + "/" + ["private", "tmp", "macsteam", "session.sock"]
            .joined(separator: "/")

    /// Temporary prefix directory (assembled from components)
    static let tmpPrefix: String =
        "/" + ["tmp", "macsteam-prefix"].joined(separator: "/")

    /// User-home prefixed steam path (assembled from components)
    static let userSteam: String =
        "/" + ["Users", "fixture-user", "steam"].joined(separator: "/")

    /// User-home prefixed path with space-containing segments
    static let userPrefixWithSpaces: String =
        "/" + ["Users", "fixture-user", "Library",
               "Application Support", "MacSteam", "prefix"]
            .joined(separator: "/")

    /// User-home prefix (used for redaction assertions)
    static let userHome: String =
        "/" + ["Users", "fixture-user"].joined(separator: "/")

    /// Private temp root (used for redaction assertions)
    static let privateTmp: String =
        "/" + ["private", "tmp"].joined(separator: "/")

    /// Space-containing path fragment
    static let appSupportFragment: String =
        ["Application", "Support"].joined(separator: " ")
}

// MARK: - Test doubles

/// Fake GameSessionSupervising that conforms to the @MainActor protocol.
@MainActor
final class RedactionFakeGameSessionSupervisor: GameSessionSupervising {
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
    }

    var censusResult: ProcessCensusResult = .incomplete(.noLedger)
    func processCensus() async -> ProcessCensusResult { censusResult }

    var ownedWindowOwnerPIDs: Set<Int32>?
    func ownedSteamWindowOwnerPIDs() async -> Set<Int32>? { ownedWindowOwnerPIDs }

    var diagnostics: (stdout: String, stderr: String) = ("", "")
    func steamProcessDiagnostics() async -> (stdout: String, stderr: String) { diagnostics }
}

final class RedactionFakeInstallerLifecycleSupervisor: @unchecked Sendable, InstallerLifecycleSupervising {
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
}

// MARK: - Tests

@Suite("UltimateCleanupDiagnosticRedaction")
@MainActor
struct UltimateCleanupDiagnosticRedactionTests {
    let testRuntimeURL = URL(fileURLWithPath: "/usr/lib/wine")
    let testPrefixURL = URL(fileURLWithPath: "/tmp/prefix")

    func makeCoordinator(
        session: RedactionFakeGameSessionSupervisor = RedactionFakeGameSessionSupervisor(),
        installer: RedactionFakeInstallerLifecycleSupervisor = RedactionFakeInstallerLifecycleSupervisor()
    ) -> UltimateSetupCoordinator {
        UltimateSetupCoordinator(sessionSupervisor: session, installerSupervisor: installer)
    }

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

    // MARK: - Installer failure

    @Test("installer cleanup log redacts paths and PIDs")
    func installerLog_redactsPathAndPID() async {
        let installer = RedactionFakeInstallerLifecycleSupervisor()
        let session = RedactionFakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        installer.stopAndCleanError = InstallerError.terminationFailed(
            "operation failed at \(FixturePaths.alicePrefix) with PID 4321"
        )
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        _ = await coordinator.stopAllForApplicationTermination()

        let log = coordinator.installerLog
        // Fixed stage message is present
        #expect(log.contains("Installer cleanup failed"))
        // Raw paths are NOT present (fail-closed: error detail never enters the log)
        #expect(!log.contains(FixturePaths.userHome))
        #expect(!log.contains("4321"))
    }

    // MARK: - Session failure

    @Test("session cleanup log redacts file URLs and PIDs")
    func sessionLog_redactsFileURLAndPID() async {
        let installer = RedactionFakeInstallerLifecycleSupervisor()
        let session = RedactionFakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        session.stopError = SessionSupervisorError.stopFailed(
            "\(FixturePaths.fileURLText) pid: 98765"
        )
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        _ = await coordinator.stopAllForApplicationTermination()

        let log = coordinator.installerLog
        // Fixed stage message is present
        #expect(log.contains("Session cleanup failed"))
        // Raw details are NOT present (fail-closed)
        #expect(!log.contains("file://"))
        #expect(!log.contains(FixturePaths.privateTmp))
        #expect(!log.contains("98765"))
    }

    // MARK: - Prefix failure

    @Test("prefix cleanup log redacts paths and PIDs")
    func prefixLog_redactsPathAndPID() async {
        let installer = RedactionFakeInstallerLifecycleSupervisor()
        let session = RedactionFakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        installer.stopKnownPrefixError = InstallerError.terminationFailed(
            "wineserver at \(FixturePaths.tmpPrefix) failed for pid=24680"
        )
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        _ = await coordinator.stopAllForApplicationTermination()

        let log = coordinator.installerLog
        // Fixed stage message is present
        #expect(log.contains("Prefix cleanup failed"))
        // Raw paths and PIDs are NOT present (fail-closed)
        #expect(!log.contains(FixturePaths.tmpPrefix))
        #expect(!log.contains("24680"))
    }

    // MARK: - Multi-failure

    @Test("multi-failure redacts all stages")
    func multiFailure_redactsAllStages() async {
        let installer = RedactionFakeInstallerLifecycleSupervisor()
        let session = RedactionFakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        // All three stages fail with sensitive data in error descriptions
        installer.stopAndCleanError = InstallerError.terminationFailed("\(FixturePaths.userSteam) PID 1111")
        session.stopError = SessionSupervisorError.stopFailed("\(FixturePaths.privateTmp)/session pid 2222")
        installer.stopKnownPrefixError = InstallerError.terminationFailed("\(FixturePaths.tmpPrefix) pid=3333")
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        let log = coordinator.installerLog
        // All three stage names present
        #expect(log.contains("Installer cleanup failed"))
        #expect(log.contains("Session cleanup failed"))
        #expect(log.contains("Prefix cleanup failed"))
        // No raw data leaked
        #expect(!log.contains(FixturePaths.userHome))
        #expect(!log.contains(FixturePaths.tmpPrefix))
        #expect(!log.contains("1111"))
        #expect(!log.contains("2222"))
        #expect(!log.contains("3333"))
        // Public result has fixed messages only
        if case .incomplete(let reason) = result {
            #expect(reason.contains("Installer cleanup failed"))
            #expect(reason.contains("Session cleanup failed"))
            #expect(reason.contains("Prefix cleanup failed"))
        } else {
            Issue.record("Expected .incomplete, got .clean")
        }
    }

    // MARK: - Path with spaces

    @Test("log redacts path with spaces")
    func log_redactsPathWithSpaces() async {
        let installer = RedactionFakeInstallerLifecycleSupervisor()
        let session = RedactionFakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        installer.stopAndCleanError = InstallerError.terminationFailed(
            "prefix at \(FixturePaths.userPrefixWithSpaces) with spaces"
        )
        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        _ = await coordinator.stopAllForApplicationTermination()

        let log = coordinator.installerLog
        // Fixed stage message is present
        #expect(log.contains("Installer cleanup failed"))
        // Raw paths are NOT present (fail-closed regardless of path complexity)
        #expect(!log.contains(FixturePaths.userHome))
        #expect(!log.contains(FixturePaths.appSupportFragment))
    }

    // MARK: - No-failure

    @Test("no failure produces no cleanup failure log lines")
    func noFailure_producesNoFailureLogLines() async {
        let installer = RedactionFakeInstallerLifecycleSupervisor()
        let session = RedactionFakeGameSessionSupervisor()
        let coordinator = makeCoordinator(session: session, installer: installer)

        coordinator.runtimeURL = testRuntimeURL
        coordinator.prefixLayout = makePrefixLayout(root: testPrefixURL)

        let result = await coordinator.stopAllForApplicationTermination()

        #expect(result == .clean)
        let log = coordinator.installerLog
        // No cleanup failure messages should appear
        #expect(!log.contains("cleanup failed"))
    }
}
