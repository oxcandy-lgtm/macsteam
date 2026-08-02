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

    // MARK: - U1R18 FIX1: fail-closed census + ownership ledger

    @Test("census from current process is proven and error-free")
    func censusCurrentProcessProven() throws {
        guard let rootSnap = HostProcessLineage.snapshot(pid: getpid()) else {
            Issue.record("root snapshot must exist for the test process")
            return
        }
        var ledger = ProcessCensusLedger(rootIdentity: rootSnap.identity)
        let result = HostProcessLineage.census(ledger: &ledger)
        #expect(result.state == .proven)
        #expect(result.error == nil)
        #expect(result.liveDescendants >= 0)
        #expect(result.totalLive >= 0)
    }

    @Test("census is incomplete when root process is gone")
    func censusRootNotFound() {
        let id = ProcessIdentity(
            pid: 999999, startSeconds: 1, startMicroseconds: 0,
            executableName: "none", canonicalExecutable: "none"
        )
        var ledger = ProcessCensusLedger(rootIdentity: id)
        let result = HostProcessLineage.census(ledger: &ledger)
        #expect(result.state == .incomplete)
        #expect(result.error == .rootNotFound(999999))
        #expect(result.totalLive == 0)
    }

    @Test("census fails closed when root identity drifts from launch capture")
    func censusRootIdentityMismatch() {
        guard let rootSnap = HostProcessLineage.snapshot(pid: getpid()) else { return }
        let drifted = ProcessIdentity(
            pid: rootSnap.identity.pid,
            startSeconds: rootSnap.identity.startSeconds + 1,
            startMicroseconds: rootSnap.identity.startMicroseconds,
            executableName: rootSnap.identity.executableName,
            canonicalExecutable: rootSnap.identity.canonicalExecutable
        )
        var ledger = ProcessCensusLedger(rootIdentity: drifted)
        let result = HostProcessLineage.census(ledger: &ledger)
        #expect(result.state == .incomplete)
        #expect(result.error == .rootIdentityMismatch)
        #expect(result.totalLive == 0)
    }

    @Test("census snapshot captures start microseconds and canonical executable for PID-reuse identity")
    func censusSnapshotIdentityFields() throws {
        guard let snap = HostProcessLineage.snapshot(pid: getpid()) else {
            Issue.record("snapshot must exist")
            return
        }
        #expect(snap.identity.startSeconds > 0)
        #expect(snap.identity.startMicroseconds > 0)
        #expect(!snap.identity.canonicalExecutable.isEmpty)
        #expect(snap.identity.matches(snap.identity))
    }

    @Test("reconcile admits an orphan only from a previously observed ledger entry")
    func reconcileObservedOrphan() {
        let root = makeSnap(100, 1, name: "root")
        let child = makeSnap(200, 100, name: "child")
        let orphan = makeSnap(300, 1, name: "orphan") // ppid = launchd, no longer reachable
        var ledger = ProcessCensusLedger(rootIdentity: root.identity)
        ledger.record(child.identity)
        ledger.record(orphan.identity)
        let all: [Int32: HostProcessSnapshot] = [100: root, 200: child, 300: orphan]
        let result = HostProcessLineage.reconcile(ledger: &ledger, root: root, all: all)
        #expect(result.state == .proven)
        #expect(result.liveDescendants == 1)
        #expect(result.liveOrphans == 1)
        #expect(result.totalLive == 2)
    }

    @Test("reconcile never admits an unobserved orphan")
    func reconcileRejectsUnobservedOrphan() {
        let root = makeSnap(100, 1, name: "root")
        let stranger = makeSnap(300, 1, name: "stranger") // not a descendant, never observed
        var ledger = ProcessCensusLedger(rootIdentity: root.identity)
        let all: [Int32: HostProcessSnapshot] = [100: root, 300: stranger]
        let result = HostProcessLineage.reconcile(ledger: &ledger, root: root, all: all)
        #expect(result.liveOrphans == 0)
        #expect(result.liveDescendants == 0)
    }

    @Test("reconcile counts previously observed processes that exited")
    func reconcileExited() {
        let root = makeSnap(100, 1, name: "root")
        let child = makeSnap(200, 100, name: "child")
        var ledger = ProcessCensusLedger(rootIdentity: root.identity)
        ledger.record(child.identity)
        ledger.record(makeSnap(300, 200, name: "gone").identity)
        let all: [Int32: HostProcessSnapshot] = [100: root, 200: child]
        let result = HostProcessLineage.reconcile(ledger: &ledger, root: root, all: all)
        #expect(result.state == .proven)
        #expect(result.exitedCount == 1)
        #expect(!ledger.observed.contains(where: { $0.pid == 300 }), "exited process must be pruned")
    }

    @Test("reconcile rejects a reused PID via stable identity mismatch")
    func reconcilePidReuse() {
        let root = makeSnap(100, 1, name: "root")
        var ledger = ProcessCensusLedger(rootIdentity: root.identity)
        ledger.record(makeSnap(200, 100, startSec: 1000, name: "old").identity)
        let reused = makeSnap(200, 100, startSec: 5000, name: "new") // same PID, different start
        let all: [Int32: HostProcessSnapshot] = [100: root, 200: reused]
        let result = HostProcessLineage.reconcile(ledger: &ledger, root: root, all: all)
        #expect(result.pidReuseCount == 1)
        #expect(result.liveDescendants == 0)
        #expect(!ledger.observed.contains(where: { $0.pid == 200 }), "reused PID must be pruned")
    }

    @Test("reconcile keeps zombie and orphan accounting distinct")
    func reconcileZombieOrphanDistinct() {
        let root = makeSnap(100, 1, name: "root")
        let zombie = makeSnap(200, 100, startSec: 2000, name: "z", state: .zombie)
        let orphan = makeSnap(300, 1, startSec: 3000, name: "o")
        var ledger = ProcessCensusLedger(rootIdentity: root.identity)
        ledger.record(zombie.identity)
        ledger.record(orphan.identity)
        let all: [Int32: HostProcessSnapshot] = [100: root, 200: zombie, 300: orphan]
        let result = HostProcessLineage.reconcile(ledger: &ledger, root: root, all: all)
        #expect(result.zombieCount == 1)
        #expect(result.liveOrphans == 1)
        #expect(result.liveDescendants == 0)
        #expect(result.zombieCount + result.liveOrphans == 2, "zombie and orphan must not be merged")
    }

    @Test("supervisor census fails closed when no session ledger exists")
    @MainActor
    func supervisorCensusNoLedger() async {
        let supervisor = GameSessionSupervisor()
        let result = await supervisor.processCensus()
        #expect(result.state == .incomplete)
        #expect(result.error == .noLedger)
    }

    // MARK: - Helpers

    private func makeIdentity(
        _ pid: Int32,
        _ startSec: UInt64 = 1000,
        name: String = "x",
        startUsec: UInt64 = 0
    ) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startSeconds: startSec,
            startMicroseconds: startUsec,
            executableName: name,
            canonicalExecutable: "/bin/\(name)"
        )
    }

    private func makeSnap(
        _ pid: Int32,
        _ ppid: Int32,
        startSec: UInt64 = 1000,
        name: String = "x",
        state: HostProcessState = .sleeping
    ) -> HostProcessSnapshot {
        HostProcessSnapshot(
            identity: makeIdentity(pid, startSec, name: name),
            ppid: ppid,
            state: state
        )
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
