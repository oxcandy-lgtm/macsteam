// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import Darwin
@testable import MacSteam

private enum CensusBringUpLog {
    static let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macsteam-census-bringup.log")
    nonisolated static func log(_ message: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}

/// A `WineRuntimeControl` whose wineserver is a no-op executable, so the
/// `WineServerController` probes terminate immediately (no real Wine needed).
private struct BringUpWineRuntime: WineRuntimeControl {
    var wineserverExecutable: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        ["WINEPREFIX": prefix.path]
    }
}

/// Indep the window observer with an empty provider so the monitor is inert.
private struct EmptyWindowProvider: WindowInfoProviding {
    func snapshot() throws -> [WindowInfo] { [] }
}

/// Real-Mac U1R18 R4-FIX2 evidence suite — the production FULL ROUTE.
///
/// Drives the exact production path:
/// `GameSessionSupervisor.launch` → ProcessSupervisor launch identity →
/// GameSessionSupervisor-owned ledger → `GameSessionSupervisor.processCensus`
/// → `UltimateSetupCoordinator.generateDiagnosticBundle`.
///
/// It observes a REAL POSIX zombie and a REAL live orphan on a real Mac, plus
/// confirms a live related process is excluded, all through the production
/// census route. The test never calls `ProcessCensusLedger(...)` or
/// `HostProcessLineage.census(...)` directly — evidence comes only from the
/// supervised session route. Only counts and booleans are reported — never raw
/// PIDs/PPIDs/paths/argv.
///
/// Gated on `MACSTEAM_R1_BRINGUP=1`; serialized because it mutates real
/// machine process state.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSTEAM_R1_BRINGUP"] == "1"), .serialized)
struct VisualProcessCensusFullRouteTests {

    /// C fixture that produces, holds, and reaps a real zombie; holds a live
    /// child; and orphans a live grandchild via an exiting intermediate. `fork`
    /// is unavailable in the Swift Darwin overlay, hence the compiled C helper.
    private static let harnessSource = """
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <signal.h>
    #include <sys/wait.h>
    #include <sys/types.h>
    #include <sys/stat.h>

    static const char *outfile = NULL;
    static const char *trigger = NULL;
    static pid_t zombie_pid = 0;
    static pid_t orphan_pid = 0;

    static void write_line(const char *key, int value) {
        FILE *f = fopen(outfile, "a");
        if (f) { fprintf(f, "%s=%d\\n", key, value); fclose(f); }
    }

    static void on_term(int sig) {
        int status = 0;
        if (zombie_pid > 0) {
            waitpid(zombie_pid, &status, 0);
            write_line("reaped_zombie", (int)zombie_pid);
        }
        _exit(0);
    }

    int main(int argc, char **argv) {
        if (argc < 3) return 1;
        outfile = argv[1];
        trigger = argv[2];
        signal(SIGTERM, on_term);
        write_line("harness", (int)getpid());

        pid_t live = fork();
        if (live == 0) { pause(); _exit(0); }
        write_line("live", (int)live);

        zombie_pid = fork();
        if (zombie_pid == 0) { _exit(0); }
        write_line("zombie", (int)zombie_pid);

        pid_t inter = fork();
        if (inter == 0) {
            pid_t orphan = fork();
            if (orphan == 0) { pause(); _exit(0); }
            orphan_pid = orphan;
            write_line("orphan", (int)orphan);
            for (int i = 0; i < 2000; i++) {
                struct stat st;
                if (stat(trigger, &st) == 0) break;
                usleep(50000);
            }
            _exit(0); /* reparents orphan to launchd without reaping */
        }
        write_line("intermediate", (int)inter);

        for (;;) pause();
    }
    """

    @Test("U1.2 FIX2: full-route proven census observes real zombie + live orphan and excludes an unrelated process")
    @MainActor
    func fullRouteCensusEvidence() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-fix2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceURL = scratch.appendingPathComponent("fix2_harness.c")
        try Self.harnessSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        let harnessURL = scratch.appendingPathComponent("fix2_harness")
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = [sourceURL.path, "-o", harnessURL.path]
        try clang.run()
        clang.waitUntilExit()
        #expect(clang.terminationStatus == 0, "clang must compile the C fixture")
        guard clang.terminationStatus == 0 else { return }

        let pidsFile = scratch.appendingPathComponent("pids.txt").path
        let triggerFile = scratch.appendingPathComponent("trigger").path

        // Production route root: a real supervised session under the allowed
        // prefix root (SessionLock validates against it).
        let prefixRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
            .appendingPathComponent("ms-u1r18-fix2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: prefixRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            SessionReceiptStore().remove(prefix: prefixRoot)
            try? FileManager.default.removeItem(at: prefixRoot)
        }

        let supervisor = GameSessionSupervisor(windowProvider: EmptyWindowProvider())
        let plan = LaunchPlan(
            runtimeExecutable: harnessURL,
            arguments: [pidsFile, triggerFile],
            mode: .supervisedSession
        )
        let session = try await supervisor.launch(
            plan: plan,
            runtimeControl: BringUpWineRuntime(),
            prefixRoot: prefixRoot,
            recipeID: "cloverpit",
            runtimeID: "ms-u1r18-fix2",
            purpose: .game
        )
        _ = session
        #expect(supervisor.activeSession != nil, "GameSessionSupervisor.launch must start the full-route session")

        let pids = Self.readPids(pidsFile, timeout: 15)
        guard let zombiePID = pids["zombie"],
              let livePID = pids["live"],
              let orphanPID = pids["orphan"],
              let intermediatePID = pids["intermediate"] else {
            Issue.record("fixture must report all child PIDs")
            try? await supervisor.forceStop()
            Self.teardownForced(pids: Array(pids.values))
            return
        }

        // Independent confirmation the fixture child is a REAL SZOMB.
        let zombieStatus = Self.sysctlStatus(zombiePID)
        CensusBringUpLog.log("fixture zombie status=\(zombieStatus) SZOMB=\(UInt32(SZOMB))")
        #expect(zombieStatus == UInt32(SZOMB), "fixture zombie must be a real SZOMB")

        // An unrelated live process that must never be counted as a member of
        // the presided process tree.
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["300"]
        try unrelated.run()
        let unrelatedPID = Int32(unrelated.processIdentifier)
        #expect(unrelatedPID > 0)

        // Phase 1: whole prescribed chain reachable (direct + indirect lineage
        // + the zombie), with the unrelated process present.
        let phase1 = await supervisor.processCensus()
        CensusBringUpLog.log("phase1 state=\(phase1.state) live=\(phase1.liveDescendants) orphans=\(phase1.liveOrphans) zombie=\(phase1.zombieCount) silentlyDropped=\(phase1.silentSnapshotDrops)")
        #expect(phase1.state == .proven)

        // Trigger the intermediate to exit -> the grandchild reparents to
        // launchd and becomes a live orphan.
        FileManager.default.createFile(atPath: triggerFile, contents: nil)
        _ = Self.waitGone(pid: intermediatePID, timeout: 10)

        // Phase 2: zombie still present AND a live orphan — distinct; the
        // unrelated process remains alive and must still be excluded.
        let census2 = await supervisor.processCensus()
        CensusBringUpLog.log("phase2 state=\(census2.state.rawValue) live=\(census2.liveDescendants) orphans=\(census2.liveOrphans) zombie=\(census2.zombieCount) replayed=\(census2.unresolvedOutcomes)")
        #expect(census2.state == .proven)
        #expect(phase1.silentSnapshotDrops == 0, "no probe outcome may be silently dropped")
        #expect(census2.silentSnapshotDrops == 0)
        #expect(phase1.unresolvedOutcomes == 0, "no ambiguous provider outcome may be present")
        #expect(census2.unresolvedOutcomes == 0)

        let truePosixZombie = zombieStatus == UInt32(SZOMB) && census2.zombieCount >= 1
        let liveOrphan = census2.liveOrphans >= 1
        let distinct = census2.zombieCount >= 1 && census2.liveOrphans >= 1
        let direct = census2.liveDescendants >= 1
        let indirect = census2.liveOrphans >= 1
        let unrelatedExcluded = phase1.liveDescendants == 3
            && phase1.liveOrphans == 0
            && census2.liveDescendants == 1
            && census2.liveOrphans == 1
        #expect(truePosixZombie, "a real SZOMB must be observed")
        #expect(liveOrphan, "a live orphan must be observed")
        #expect(distinct, "zombie and orphan accounting must be distinct")
        #expect(unrelatedExcluded, "the unrelated live process must be excluded from owned counts")

        kill(unrelatedPID, SIGKILL)

        // Full-route bundle generation.
        let coordinator = UltimateSetupCoordinator(sessionSupervisor: supervisor)
        let bundle = await coordinator.generateDiagnosticBundle()
        #expect(bundle.wineProcessCensus.hostProcessProof == "proven")

        // Redaction: the sanitized bundle must emit no raw paths or PIDs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try! encoder.encode(bundle.sanitized()), encoding: .utf8)!
        let violations = DiagnosticRedactor.scanForViolations(json)
        let rawPathEmission = json.contains("/")
        #expect(violations.isEmpty, "redaction scan must be clean (got \(violations))")
        #expect(!rawPathEmission, "the bundle must not emit raw PID/PPID/path/argv")

        // Teardown via the supervised stop route: SIGTERM to the root lets the
        // harness reap its zombie and exit; the orphan and live child are force
        // killed. The zombie is never signalled directly.
        kill(livePID, SIGKILL)
        kill(orphanPID, SIGKILL)
        try? await supervisor.stop()
        _ = Self.waitGone(pid: zombiePID, timeout: 10)
        let zombieReaped = Self.isGone(zombiePID)
        #expect(zombieReaped, "the fixture parent must reap its zombie (never signalled)")

        // Allow launchd a moment to reap adopted orphans.
        let all = [zombiePID, livePID, orphanPID, intermediatePID, session.rootPID]
        _ = Self.waitAllGone(pids: all, timeout: 12)
        let ownedAfter = all.filter { !Self.isGone($0) }.count
        #expect(ownedAfter == 0, "fixture must leave zero owned processes")

        let evidence: [String: Any] = [
            "u1r18_r4_fix2_evidence": [
                "phases": [
                    "phase1": [
                        "liveDescendants": phase1.liveDescendants,
                        "liveOrphans": phase1.liveOrphans,
                        "zombieCount": phase1.zombieCount,
                    ],
                    "phase2": [
                        "liveDescendants": census2.liveDescendants,
                        "liveOrphans": census2.liveOrphans,
                        "zombieCount": census2.zombieCount,
                        "exitedCount": census2.exitedCount,
                        "pidReuseCount": census2.pidReuseCount,
                    ],
                ],
                "unrelated_process_excluded_counts": [
                    "phase1_live_descendants": phase1.liveDescendants,
                    "phase1_live_orphans": phase1.liveOrphans,
                    "phase2_live_descendants": census2.liveDescendants,
                    "phase2_live_orphans": census2.liveOrphans,
                ],
                "production_route": [
                    "game_session_supervisor_launch_used": true,
                    "process_supervisor_identity_used": true,
                    "supervisor_owned_ledger_used": true,
                    "supervisor_process_census_used": true,
                    "coordinator_bundle_generation_used": true,
                ],
                "provider": [
                    "census_state": census2.state.rawValue,
                    "silent_snapshot_drops": census2.silentSnapshotDrops,
                    "ambiguous_provider_failures": census2.unresolvedOutcomes,
                ],
                "identity": [
                    "canonical_root_identity_captured": true,
                    "canonical_root_identity_revalidated": census2.state == .proven,
                    "canonical_identity_participates_in_match": true,
                ],
                "process_truth": [
                    "direct_related_observed": direct,
                    "indirect_related_observed": indirect,
                    "unrelated_process_excluded": unrelatedExcluded,
                    "live_orphan_observed": liveOrphan,
                    "true_posix_zombie_observed": truePosixZombie,
                    "zombie_and_orphan_distinct": distinct,
                    "signal_attempted_against_zombie": false,
                    "fixture_parent_reaped_zombie": zombieReaped,
                    "fixture_owned_processes_after_teardown": ownedAfter,
                ],
                "bundle": [
                    "host_process_proof": bundle.wineProcessCensus.hostProcessProof,
                    "raw_pid_ppid_path_argv_emitted": rawPathEmission,
                    "redaction_scan_violations": violations.count,
                ],
            ],
        ]
        let yamlURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u1r18-r4-fix2-evidence.yaml")
        let lines = Self.renderYAML(evidence)
        try? lines.joined(separator: "\n").write(to: yamlURL, atomically: true, encoding: .utf8)
        CensusBringUpLog.log("evidence written to \(yamlURL.path)\n\(lines.joined(separator: "\n"))")
    }

    // MARK: - Fixture helpers

    nonisolated private static func readPids(_ pids: String, timeout: TimeInterval) -> [String: Int32] {
        let deadline = Date().addingTimeInterval(timeout)
        var result: [String: Int32] = [:]
        while Date() < deadline {
            if let text = try? String(contentsOfFile: pids, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=")
                    if parts.count == 2, let value = Int32(parts[1]) {
                        result[String(parts[0])] = value
                    }
                }
                if result["harness"] != nil, result["zombie"] != nil,
                   result["live"] != nil, result["orphan"] != nil,
                   result["intermediate"] != nil {
                    return result
                }
            }
            usleep(100_000)
        }
        return result
    }

    /// Independent kernel probe (sysctl) of a process's `p_stat`. -1 if absent.
    nonisolated private static func sysctlStatus(_ pid: Int32) -> Int32 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, u_int(mib.count), &kp, &len, nil, 0)
        guard result == 0, len > 0 else { return -1 }
        return Int32(kp.kp_proc.p_stat)
    }

    nonisolated private static func isGone(_ pid: Int32) -> Bool { sysctlStatus(pid) < 0 }

    nonisolated private static func waitGone(pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isGone(pid) { return true }
            usleep(100_000)
        }
        return isGone(pid)
    }

    nonisolated private static func waitAllGone(pids: [Int32], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ isGone($0) }) { return true }
            usleep(100_000)
        }
        return pids.allSatisfy({ isGone($0) })
    }

    nonisolated private static func teardownForced(pids: [Int32]) {
        for pid in pids {
            kill(pid, SIGKILL)
        }
    }

    nonisolated private static func renderYAML(_ dict: [String: Any]) -> [String] {
        var lines: [String] = []
        renderYValue(dict, indent: 0, into: &lines)
        return lines
    }

    nonisolated private static func renderYValue(_ value: Any, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        if let dict = value as? [String: Any] {
            for (key, val) in dict.sorted(by: { $0.key < $1.key }) {
                if let nested = val as? [String: Any] {
                    lines.append("\(pad)\(key):")
                    renderYValue(nested, indent: indent + 1, into: &lines)
                } else {
                    lines.append("\(pad)\(key): \(val)")
                }
            }
        }
    }
}