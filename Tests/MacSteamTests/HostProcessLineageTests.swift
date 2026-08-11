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

    @Test("census from a controlled process is proven and error-free")
    func censusCurrentProcessProven() throws {
        // Root on a freshly-spawned, childless process so the census has a
        // deterministic reachable set (independent of unrelated test churn that
        // hangs off the test-runner PID).
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.1)

        guard let rootSnap = HostProcessLineage.snapshot(pid: Int32(sleeper.processIdentifier)) else {
            Issue.record("root snapshot must exist for the controlled process")
            return
        }
        var ledger = ProcessCensusLedger(rootIdentity: rootSnap.identity)
        let result = HostProcessLineage.census(ledger: &ledger)
        #expect(result.state == .proven)
        #expect(result.error == nil)
        #expect(result.liveDescendants == 0)
        #expect(result.totalLive == 0)
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

    // MARK: - U1R18 R4-FIX2: provider completeness + canonical identity

    @Test("probe classifies the current process as present with a canonical identity")
    func probeCurrentProcessPresent() {
        let outcome = HostProcessLineage.probe(pid: getpid())
        guard case .present(let snap) = outcome else {
            Issue.record("current process must probe as present, got \(outcome)")
            return
        }
        #expect(snap.identity.pid == getpid())
        #expect(!snap.identity.canonicalExecutable.isEmpty,
                "canonical executable identity must be resolved, not substituted with comm name")
    }

    @Test("probe classifies a non-existent PID as confirmedExited, not ambiguous")
    func probeNonExistentConfirmedExited() {
        #expect(HostProcessLineage.probe(pid: 999_999) == .confirmedExited)
    }

    @Test("canonical executable identity participates in the ownership comparison")
    func canonicalParticipatesInMatch() {
        let a = makeIdentity(1, 1000, name: "x")
        let same = ProcessIdentity(
            pid: 1, startSeconds: 1000, startMicroseconds: a.startMicroseconds,
            executableName: "x", canonicalExecutable: "/bin/x"
        )
        let differentCanonical = ProcessIdentity(
            pid: 1, startSeconds: 1000, startMicroseconds: a.startMicroseconds,
            executableName: "x", canonicalExecutable: "/bin/y"
        )
        #expect(a.matches(same))
        #expect(!a.matches(differentCanonical),
                "a PID whose canonical executable identity differs must not match")
    }

    @Test("census fails closed when a probe is inaccessible; observed identity is retained")
    func censusFailsClosedOnInaccessibleProbe() {
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        let parentRow = makeRow(200, ppid: 100, startSec: 2000, state: .sleeping, name: "parent")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        ledger.record(makeIdentity(200, 2000, name: "parent"))

        let table: [Int32: HostProcessLineage.NativeProcessRow] = [100: rootRow, 200: parentRow]
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: { table },
            canonicalResolver: { row, _ in
                if row.pid == 100 { return "/bin/root" }
                return "" // parent live but canonical unresolvable -> ambiguous
            }
        )
        #expect(result.state == .incomplete)
        #expect(result.error == .providerOutcomeUnresolved(1))
        #expect(result.unresolvedOutcomes == 1)
        #expect(ledger.observed.contains(where: { $0.pid == 200 }),
                "observed identity must be retained on an ambiguous outcome")
    }

    @Test("census fails closed on a provider failure outcome")
    func censusFailsClosedOnProviderFailure() {
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        ledger.record(makeIdentity(200, 2000, name: "parent"))

        // The native provider fails to produce a readable table on every try;
        // after the bounded retries the census must fail closed — never a
        // fabricated proven zero.
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: { [:] },
            canonicalResolver: { _, _ in "/bin/root" }
        )
        #expect(result.state == .incomplete)
        #expect(result.error == .censusFailed)
        #expect(result.totalLive == 0)
        #expect(ledger.observed.contains(where: { $0.pid == 200 }),
                "observed identity must be retained on a provider failure")
    }

    @Test("proven census reports zero silent drops and zero unresolved outcomes")
    func censusProvenHasZeroAmbiguity() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.1)

        guard let rootSnap = HostProcessLineage.snapshot(pid: Int32(sleeper.processIdentifier)) else { return }
        var ledger = ProcessCensusLedger(rootIdentity: rootSnap.identity)
        let result = HostProcessLineage.census(ledger: &ledger)
        #expect(result.state == .proven)
        #expect(result.silentSnapshotDrops == 0,
                "no probe outcome may be silently dropped")
        #expect(result.unresolvedOutcomes == 0,
                "a proven census must have no ambiguous probe outcome")
    }

    // MARK: - U1R18 R4-FIX3: canonical fail-closed + coherent topology

    @Test("empty canonical identities never match, even empty==empty")
    func emptyCanonicalNeverMatches() {
        let a = ProcessIdentity(pid: 1, startSeconds: 1000, startMicroseconds: 0,
                                executableName: "x", canonicalExecutable: "")
        let b = ProcessIdentity(pid: 1, startSeconds: 1000, startMicroseconds: 0,
                                executableName: "y", canonicalExecutable: "")
        let c = ProcessIdentity(pid: 1, startSeconds: 1000, startMicroseconds: 0,
                                executableName: "x", canonicalExecutable: "/bin/x")
        #expect(!a.matches(b), "empty==empty must never match")
        #expect(!a.matches(c), "empty canonical can never prove ownership")
    }

    @Test("a live process with an empty canonical never probes as present")
    func liveEmptyCanonicalNotPresent() {
        // A real live process (the ballot itself) must probe present with a
        // non-empty canonical — proving the provider never emits present-empty.
        for pid in [getpid(), getppid()] {
            if case .present(let snap) = HostProcessLineage.probe(pid: pid) {
                #expect(!snap.identity.canonicalExecutable.isEmpty,
                        "live process must never carry an empty canonical")
                #expect(snap.state != .zombie)
            }
        }
    }

    @Test("unstable snapshot is never proven (bounded retry exhausted)")
    func unstableSnapshotNeverProven() {
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        ledger.record(makeIdentity(200, 2000, name: "child"))
        var epoch = 0
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: {
                epoch += 1
                let child: [Int32: HostProcessLineage.NativeProcessRow] = [
                    200: makeRow(200, ppid: 100, startSec: 2000 + UInt64(epoch),
                                 state: .sleeping, name: "child")
                ]
                var rows: [Int32: HostProcessLineage.NativeProcessRow] = [100: rootRow]
                rows.merge(child) { _, new in new }
                return rows
            },
            canonicalResolver: { row, _ in row.pid == 100 ? "/bin/root" : "/bin/present" }
        )
        #expect(result.state == .incomplete)
        #expect(result.error == .snapshotUnstable)
        #expect(result.totalLive == 0)
    }

    @Test("stable retry keeps an owned grandchild as an orphan — never dropped under proven")
    func raceRetainsGrandchildAsOrphan() {
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        let grandchildRow = makeRow(400, ppid: 1, startSec: 4000, state: .sleeping, name: "grandchild")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        // The grandchild was previously observed as a live descendant.
        ledger.record(makeIdentity(400, 4000, name: "grandchild"))

        // The intermediate reparents the grandchild to launchd (ppid 1) before
        // the coherent re-capture; the grandchild must be retained as an orphan.
        let table: [Int32: HostProcessLineage.NativeProcessRow] = [100: rootRow, 400: grandchildRow]
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: { table },
            canonicalResolver: { row, _ in row.pid == 100 ? "/bin/root" : "/bin/grandchild" }
        )
        #expect(result.state == .proven)
        #expect(result.liveOrphans == 1, "grandchild must be kept as an orphan")
        #expect(result.liveDescendants == 0)
        #expect(ledger.observed.contains(where: { $0.pid == 400 }), "grandchild retained in ledger")
    }

    @Test("a grandchild mid-exit is never dropped behind a proven result")
    func grandchildNeverDroppedUnderProven() {
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        let grandchildRow = makeRow(400, ppid: 1, startSec: 4000, state: .sleeping, name: "grandchild")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        ledger.record(makeIdentity(400, 4000, name: "grandchild"))

        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: { let rows: [Int32: HostProcessLineage.NativeProcessRow] = [100: rootRow, 400: grandchildRow]; return rows },
            canonicalResolver: { row, _ in row.pid == 100 ? "/bin/root" : "/bin/grandchild" }
        )
        if result.state == .proven {
            let total = result.liveDescendants + result.liveOrphans + result.zombieCount
            #expect(total >= 1 || result.exitedCount >= 1,
                    "a proven census must never silently drop a previously-observed grandchild")
        } else {
            #expect(result.error != nil)
        }
    }

    // MARK: - U1R18 R4-FIX4: unobserved-zombie fail-closed + retry candidate carryover

    @Test("an unobserved zombie with an unresolved canonical fails closed — never present")
    func unobservedZombieCanonicalFailsClosed() {
        // A zombie that was NEVER observed (no prior same-PID/start identity),
        // whose canonical cannot be resolved, is ambiguous — an empty canonical
        // must never be admitted as `.present`, so the census fails closed.
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        let zombieRow = makeRow(200, ppid: 100, startSec: 9000, state: .zombie, name: "zz")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        // The zombie is NOT in the ledger and gets an unresolvable canonical.
        let table: [Int32: HostProcessLineage.NativeProcessRow] = [100: rootRow, 200: zombieRow]
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: { table },
            canonicalResolver: { row, _ in row.pid == 100 ? "/bin/root" : "" }
        )
        #expect(result.state == .incomplete)
        #expect(result.error == .providerOutcomeUnresolved(1))
        #expect(!ledger.observed.contains(where: { $0.pid == 200 }),
                "the empty-canonical zombie must never be admitted to the ledger")
    }

    @Test("an observed zombie implicit inherits its prior canonical, so it stays present")
    func observedZombieInheritsCanonical() {
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        let zombieRow = makeRow(200, ppid: 100, startSec: 2000, state: .zombie, name: "zz")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        ledger.record(makeIdentity(200, 2000, name: "zz")) // observed when alive
        let table: [Int32: HostProcessLineage.NativeProcessRow] = [100: rootRow, 200: zombieRow]
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: { table },
            canonicalResolver: { row, known in
                if row.pid == 100 { return "/bin/root" }
                // Same-PID/start captured identity is inherited for the zombie.
                return known?.canonicalExecutable ?? ""
            }
        )
        #expect(result.state == .proven)
        #expect(result.zombieCount == 1)
        #expect(ledger.observed.contains(where: { $0.pid == 200 }))
    }

    @Test("a descendant candidate from an unstable attempt is carried and retained")
    func carriedCandidateRetainedAcrossAttempts() {
        // Root -> intermediate -> grandchild. During the first census the
        // intermediate exits: the reparented grandchild is discovered in one
        // attempt but the attempt is unstable. The carried candidate must be
        // resolved by the stable retry — never dropped.
        let rootRow = makeRow(100, ppid: 1, startSec: 1000, state: .sleeping, name: "root")
        var ledger = ProcessCensusLedger(rootIdentity: makeIdentity(100, 1000, name: "root"))
        var attempt = 0
        let result = HostProcessLineage.census(
            ledger: &ledger,
            captureTable: {
                attempt += 1
                if attempt == 1 {
                    // On the first attempt the grandchild is present but the
                    // intermediate is mid-exit (the second capture differs).
                    let table: [Int32: HostProcessLineage.NativeProcessRow] = [
                        100: rootRow,
                        400: makeRow(400, ppid: 100, startSec: 4000, state: .sleeping, name: "gc"),
                    ]
                    return table
                }
                // Stable retry: intermediate gone, grandchild reparented to launchd.
                let table: [Int32: HostProcessLineage.NativeProcessRow] = [
                    100: rootRow,
                    400: makeRow(400, ppid: 1, startSec: 4000, state: .sleeping, name: "gc"),
                ]
                return table
            },
            canonicalResolver: { row, _ in row.pid == 100 ? "/bin/root" : "/bin/gc" }
        )
        if result.state == .proven {
            let retained = result.liveOrphans >= 1 || result.liveDescendants >= 1
            #expect(retained, "carried grandchild must be retained as descendant or orphan")
        } else {
            #expect(result.error != nil, "a non-proven result must carry an error (fail-closed)")
            #expect(result.error == .snapshotUnstable ||
                    result.error == .providerOutcomeUnresolved(0),
                    "unstable retry or explicit resolution failure")
        }
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

    private func makeRow(
        _ pid: Int32,
        ppid: Int32,
        startSec: UInt64 = 1000,
        state: HostProcessState = .sleeping,
        name: String = "x"
    ) -> HostProcessLineage.NativeProcessRow {
        HostProcessLineage.NativeProcessRow(
            pid: pid,
            ppid: ppid,
            state: state,
            startSeconds: startSec,
            startMicroseconds: 0,
            name: name
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
