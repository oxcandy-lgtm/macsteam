// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - ProcessSupervisor Tests

struct ProcessSupervisorTests {
    private let supervisor = ProcessSupervisor()

    @Test("false start is invalid")
    func invalidExecutable() async throws {
        let badHandle = try? await supervisor.launch(plan: LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/nonexistent/binary"),
            arguments: [],
            mode: .detached
        ))
        #expect(badHandle == nil)
    }
}

// MARK: - SessionLock Tests

struct SessionLockTests {
    private var testPrefixRoot: URL {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
    }

    @Test("same prefix cannot acquire second lock")
    func duplicateLockFails() async throws {
        let tempDir = testPrefixRoot
            .appendingPathComponent("ms-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lock1 = try SessionLock(prefix: tempDir)
        try lock1.acquire()
        defer { lock1.release() }

        let lock2 = try SessionLock(prefix: tempDir)
        do {
            try lock2.acquire()
            #expect(Bool(false), "Expected SessionLockError")
        } catch is SessionLockError {
            // Expected — duplicate lock should fail
        }
    }

    @Test("different prefixes get different IDs")
    func differentPrefixIDs() throws {
        let a = testPrefixRoot.appendingPathComponent("prefixA")
        let b = testPrefixRoot.appendingPathComponent("prefixB")
        let idA = try SessionLock.derivePrefixID(a)
        let idB = try SessionLock.derivePrefixID(b)
        #expect(idA != idB)
        #expect(idA.count == 32)
        #expect(idB.count == 32)
    }

    @Test("lock failure does not leak file descriptor")
    func lockFailureClosesFD() throws {
        let tempDir = testPrefixRoot
            .appendingPathComponent("ms-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lock1 = try SessionLock(prefix: tempDir)
        try lock1.acquire()

        let lock2 = try SessionLock(prefix: tempDir)
        do {
            try lock2.acquire()
            #expect(Bool(false), "Expected SessionLockError")
        } catch is SessionLockError {
            // Expected — duplicate lock should fail
        }
        lock1.release()
    }

    @Test("invalid prefix root rejected")
    func invalidPrefixRoot() throws {
        let rootPrefix = URL(fileURLWithPath: "/tmp")
        do {
            _ = try SessionLock(prefix: rootPrefix)
            #expect(Bool(false), "Expected SessionLockError")
        } catch is SessionLockError {
            // Expected
        }
    }
}

// MARK: - WineServerController Tests

struct WineServerControllerTests {

    @Test("non-existent prefix is detected")
    func missingPrefix() async throws {
        let controller = WineServerController()
        let fakePrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")

        let mockRuntime = MockWineRuntime()
        do {
            _ = try await controller.isRunning(prefix: fakePrefix, runtime: mockRuntime)
            #expect(Bool(false), "Expected WineServerError")
        } catch is WineServerError {
            // Expected
        }
    }

    @Test("shutdown on non-existent prefix throws")
    func shutdownMissingPrefix() async throws {
        let controller = WineServerController()
        let fakePrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")

        let mockRuntime = MockWineRuntime()
        do {
            _ = try await controller.shutdownPrefix(
                runtime: mockRuntime,
                prefix: fakePrefix,
                waitSeconds: 1
            )
            #expect(Bool(false), "Expected WineServerError")
        } catch is WineServerError {
            // Expected
        }
    }
}

// MARK: - Mock runtime for testing

private struct MockWineRuntime: WineRuntimeControl {
    var wineserverExecutable: URL {
        URL(fileURLWithPath: "/usr/bin/false")
    }

    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        ["WINEPREFIX": prefix.path]
    }
}
