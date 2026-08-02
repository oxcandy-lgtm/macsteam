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
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}

/// Real-Mac U1R18 R4-FIX1 evidence suite.
///
/// Proves the production census observes a REAL POSIX zombie and a REAL live
/// orphan on a real Mac — synthetic enum-only zombie tests are prohibited from
/// satisfying the proof. The fixture is a compiled C helper (the Darwin overlay
/// marks `fork()` unavailable in Swift) that produces an unreaped `SZOMB`
/// child, a live child, and an intermediate that orphans a live grandchild.
///
/// The census runs the real production route: the root identity is captured by
/// `ProcessSupervisor` at launch and the session ledger drives
/// `HostProcessLineage.census`. Only counts and booleans are reported — never
/// raw PIDs/PPIDs/paths/argv.
///
/// Gated on `MACSTEAM_R1_BRINGUP=1`; serialized because it mutates real
/// machine process state.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSTEAM_R1_BRINGUP"] == "1"), .serialized)
struct U1R18ProcessCensusBringUpTests {

    /// C fixture that produces, holds, and reaps a real zombie; holds a live
    /// child; and orphans a live grandchild via an exiting intermediate.
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

    @Test("U1R18 FIX1: real POSIX zombie + live orphan observed through the production census")
    func realZombieAndOrphanCensusEvidence() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-fix1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceURL = scratch.appendingPathComponent("fix1_harness.c")
        try Self.harnessSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        let harnessURL = scratch.appendingPathComponent("fix1_harness")

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = [sourceURL.path, "-o", harnessURL.path]
        try clang.run()
        clang.waitUntilExit()
        #expect(clang.terminationStatus == 0, "clang must compile the C zombie fixture")
        guard clang.terminationStatus == 0 else { return }

        let pidsFile = scratch.appendingPathComponent("pids.txt").path
        let triggerFile = scratch.appendingPathComponent("trigger").path

        // Production ownership route: ProcessSupervisor captures the root
        // identity at launch; the ledger is the census authority.
        let supervisor = ProcessSupervisor()
        let plan = LaunchPlan(
            runtimeExecutable: harnessURL,
            arguments: [pidsFile, triggerFile],
            mode: .supervisedSession
        )
        let handle = try await supervisor.launch(plan: plan)
        let rootIdentity = await supervisor.capturedRootIdentity(for: handle)
        #expect(rootIdentity != nil, "ProcessSupervisor must capture the launch identity")
        guard let rootIdentity else {
            Self.teardown(pids: [handle.pid])
            return
        }

        let pids = Self.readPIDs(pidsFile, timeout: 15)
        guard let zombiePID = pids["zombie"],
              let livePID = pids["live"],
              let orphanPID = pids["orphan"],
              let intermediatePID = pids["intermediate"] else {
            Issue.record("fixture must report all child PIDs")
            Self.teardown(pids: [handle.pid])
            return
        }

        // Independent confirmation that the fixture child is a REAL zombie.
        let zombieStatus = Self.sysctlStatus(zombiePID)
        CensusBringUpLog.log("fixture zombie status=\(zombieStatus) SZOMB=\(UInt32(SZOMB))")
        #expect(zombieStatus == UInt32(SZOMB), "fixture zombie must be a real SZOMB")

        var ledger = ProcessCensusLedger(rootIdentity: rootIdentity)

        // Phase 1: harness + live + zombie + intermediate + orphan all reachable.
        let census1 = HostProcessLineage.census(ledger: &ledger)
        CensusBringUpLog.log("phase1 state=\(census1.state) liveDesc=\(census1.liveDescendants) liveOrphans=\(census1.liveOrphans) zombie=\(census1.zombieCount)")

        // Trigger the intermediate to exit → the live grandchild reparents to
        // launchd and becomes a live orphan.
        FileManager.default.createFile(atPath: triggerFile, contents: nil)
        _ = Self.waitForExit(pid: intermediatePID, timeout: 10)

        // Phase 2: zombie still present AND a live orphan — both distinct.
        let census2 = HostProcessLineage.census(ledger: &ledger)
        CensusBringUpLog.log("phase2 state=\(census2.state) liveDesc=\(census2.liveDescendants) liveOrphans=\(census2.liveOrphans) zombie=\(census2.zombieCount) exited=\(census2.exitedCount) pidReuse=\(census2.pidReuseCount)")

        let truePosixZombie = zombieStatus == UInt32(SZOMB) && census2.zombieCount >= 1
        let liveOrphan = census2.liveOrphans >= 1
        let distinct = census2.zombieCount >= 1 && census2.liveOrphans >= 1

        #expect(census2.state == .proven)
        #expect(truePosixZombie, "a real SZOMB must be observed by the production census")
        #expect(liveOrphan, "a live orphan must be observed after its parent exits")
        #expect(distinct, "zombie and orphan accounting must be distinct")

        // Teardown: the only signal to the zombie is the harness reaping it via
        // SIGTERM to the harness — never a direct signal to the zombie.
        kill(handle.pid, SIGTERM)
        _ = Self.waitForExit(pid: handle.pid, timeout: 10)
        let zombieReaped = HostProcessLineage.snapshot(pid: zombiePID) == nil
        #expect(zombieReaped, "the fixture parent must reap its zombie (never signalled)")

        kill(livePID, SIGKILL)
        kill(orphanPID, SIGKILL)

        // Give launchd a moment to reap adopted orphans.
        _ = Self.waitForAllGone(pids: [zombiePID, livePID, orphanPID, intermediatePID, handle.pid], timeout: 10)
        let ownedAfter = [zombiePID, livePID, orphanPID, intermediatePID, handle.pid]
            .filter { HostProcessLineage.snapshot(pid: $0) != nil }
            .count
        #expect(ownedAfter == 0, "fixture must leave zero owned processes after teardown")

        let evidence: [String: Any] = [
            "u1r18_r4_fix1_evidence": [
                "true_posix_zombie_observed": truePosixZombie,
                "live_orphan_observed": liveOrphan,
                "zombie_and_orphan_distinct": distinct,
                "signal_attempted_against_zombie": false,
                "fixture_parent_reaped_zombie": zombieReaped,
                "fixture_owned_processes_after_teardown": ownedAfter,
                "census_proof_proven": census2.state == .proven,
                "phase1": [
                    "liveDescendants": census1.liveDescendants,
                    "liveOrphans": census1.liveOrphans,
                    "zombieCount": census1.zombieCount,
                ],
                "phase2": [
                    "liveDescendants": census2.liveDescendants,
                    "liveOrphans": census2.liveOrphans,
                    "zombieCount": census2.zombieCount,
                    "exitedCount": census2.exitedCount,
                    "pidReuseCount": census2.pidReuseCount,
                ],
            ],
        ]
        let yamlURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u1r18-r4-fix1-evidence.yaml")
        let lines = Self.renderYAML(evidence)
        try? lines.joined(separator: "\n").write(to: yamlURL, atomically: true, encoding: .utf8)
        CensusBringUpLog.log("evidence written to \(yamlURL.path)\n\(lines.joined(separator: "\n"))")
    }

    // MARK: - Fixture helpers

    nonisolated private static func readPIDs(_ path: String, timeout: TimeInterval) -> [String: Int32] {
        let deadline = Date().addingTimeInterval(timeout)
        var result: [String: Int32] = [:]
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
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

    nonisolated private static func sysctlStatus(_ pid: Int32) -> UInt32 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, u_int(mib.count), &kp, &len, nil, 0)
        guard result == 0, len > 0 else { return 0 }
        return UInt32(kp.kp_proc.p_stat)
    }

    nonisolated private static func waitForExit(pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if HostProcessLineage.snapshot(pid: pid) == nil { return true }
            usleep(100_000)
        }
        return HostProcessLineage.snapshot(pid: pid) == nil
    }

    nonisolated private static func waitForAllGone(pids: [Int32], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ HostProcessLineage.snapshot(pid: $0) == nil }) { return true }
            usleep(100_000)
        }
        return pids.allSatisfy { HostProcessLineage.snapshot(pid: $0) == nil }
    }

    nonisolated private static func teardown(pids: [Int32]) {
        for pid in pids {
            kill(pid, SIGKILL)
        }
    }

    nonisolated private static func renderYAML(_ dict: [String: Any]) -> [String] {
        var lines: [String] = []
        renderYAMLValue(dict, indent: 0, into: &lines)
        return lines
    }

    nonisolated private static func renderYAMLValue(_ value: Any, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        if let dict = value as? [String: Any] {
            for (key, val) in dict.sorted(by: { $0.key < $1.key }) {
                if let nested = val as? [String: Any] {
                    lines.append("\(pad)\(key):")
                    renderYAMLValue(nested, indent: indent + 1, into: &lines)
                } else {
                    lines.append("\(pad)\(key): \(val)")
                }
            }
        }
    }
}
