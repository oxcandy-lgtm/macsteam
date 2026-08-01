// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import Darwin
@testable import MacSteam

struct HostProcessLineageTests {

    @Test("snapshot returns identity for current process")
    func snapshotCurrentProcess() {
        let snap = HostProcessLineage.snapshot(pid: getpid())
        #expect(snap != nil)
        #expect(snap?.identity.pid == getpid())
        #expect(snap?.state != .zombie)
        #expect(!(snap?.identity.executableName.isEmpty ?? true))
    }

    @Test("snapshot returns nil for non-existent PID")
    func snapshotNonExistent() {
        let snap = HostProcessLineage.snapshot(pid: 999999)
        #expect(snap == nil)
    }

    @Test("lineage from current process succeeds")
    func lineageCurrentProcess() throws {
        let result = try HostProcessLineage.lineage(from: getpid())
        #expect(result.rootIdentity.pid == getpid())
        #expect(result.descendantCount >= 0)
        #expect(result.totalLive >= 1)
        #expect(result.zombieCount >= 0)
    }

    @Test("lineage from non-existent PID throws rootNotFound")
    func lineageNonExistent() {
        #expect(throws: HostProcessLineage.CensusError.self) {
            try HostProcessLineage.lineage(from: 999999)
        }
    }

    @Test("identity includes start time for PID reuse prevention")
    func identityIncludesStartTime() {
        let snap = HostProcessLineage.snapshot(pid: getpid())
        #expect(snap != nil)
        #expect(snap!.identity.startSeconds > 0)
    }

    @Test("zombie state is correctly classified")
    func zombieStateClassification() {
        #expect(HostProcessState(darwinStatus: UInt32(SZOMB)) == .zombie)
        #expect(HostProcessState(darwinStatus: UInt32(SRUN)) == .running)
        #expect(HostProcessState(darwinStatus: UInt32(SSLEEP)) == .sleeping)
        #expect(HostProcessState(darwinStatus: UInt32(SSTOP)) == .stopped)
    }

    @Test("spawned child appears in lineage")
    func spawnedChildInLineage() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let childPID = Int32(process.processIdentifier)
        #expect(childPID > 0)

        let result = try HostProcessLineage.lineage(from: getpid())
        let allSnapshots = try lineagePIDs(from: getpid())
        #expect(allSnapshots.contains(childPID), "child PID should be in lineage")
    }

    @Test("spawned child→grandchild tree is captured")
    func childGrandchildTree() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 10 & sleep 10 & wait"]
        try shell.run()
        defer {
            shell.terminate()
            shell.waitUntilExit()
        }

        Thread.sleep(forTimeInterval: 0.5)

        let result = try HostProcessLineage.lineage(from: getpid())
        #expect(result.descendantCount >= 3, "shell + 2 sleeps = at least 3 descendants")
    }

    @Test("reaped process disappears from lineage")
    func reapedProcessDisappears() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["done"]
        try process.run()
        process.waitUntilExit()

        let result = try HostProcessLineage.lineage(from: getpid())
        #expect(result.zombieCount == 0, "reaped process should not be zombie")
    }

    @Test("lineage result has no raw paths or PIDs in diagnostic encoding")
    func lineageDiagnosticSafe() throws {
        let result = try HostProcessLineage.lineage(from: getpid())
        let diag = WineProcessCensusDiagnostic(
            hostProcessCount: result.descendantCount,
            zombieCount: result.zombieCount,
            orphanCount: result.orphanCount,
            totalLive: result.totalLive,
            censusError: nil,
            hostProcessProof: "proven"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(diag)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("/"))
        #expect(!json.contains("PID"))
    }

    private func lineagePIDs(from root: Int32) throws -> Set<Int32> {
        var allPIDs: [Int32] = Array(repeating: 0, count: 4096)
        let count = proc_listallpids(&allPIDs, Int32(4096 * MemoryLayout<Int32>.size))
        guard count > 0 else { return [root] }

        var parentByPID: [Int32: Int32] = [:]
        for i in 0..<Int(count) {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(allPIDs[i], PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if size > 0 {
                parentByPID[allPIDs[i]] = Int32(info.pbi_ppid)
            }
        }

        var result: Set<Int32> = [root]
        var stack: [Int32] = [root]
        while let pid = stack.popLast() {
            for (child, parent) in parentByPID where parent == pid {
                if result.insert(child).inserted {
                    stack.append(child)
                }
            }
        }
        return result
    }
}
