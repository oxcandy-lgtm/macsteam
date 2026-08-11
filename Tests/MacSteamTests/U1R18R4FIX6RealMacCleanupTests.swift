// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import Darwin
@testable import MacSteam

/// A `WineRuntimeControl` whose wineserver is a no-op executable, so probes
/// terminate immediately (no real Wine needed for the cleanup path).
private struct Fix6CleanupWineRuntime: WineRuntimeControl {
    var wineserverExecutable: URL { URL(fileURLWithPath: "/usr/bin/false") }
    func controlEnvironment(for prefix: URL) throws -> [String: String] {
        ["WINEPREFIX": prefix.path]
    }
}

/// Inert window provider.
private struct Fix6EmptyWindowProvider: WindowInfoProviding {
    func snapshot() throws -> [WindowInfo] { [] }
}

/// Real-Mac U1R18-R4-FIX6 cleanup evidence: a child that IGNORES SIGTERM must
/// still be cleaned up by the forward transaction — SIGTERM fails, the bounded
/// wait times out, SIGKILL is sent, the second reap-confirm wait confirms the
/// reap, and only then does the session reach `.stopped`.
///
/// Gated on `MACSTEAM_R1_BRINGUP=1`; serialized (mutates real process state).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSTEAM_R1_BRINGUP"] == "1"), .serialized)
struct U1R18R4FIX6RealMacCleanupTests {

    /// C fixture: writes its PID, installs a SIGTERM handler that ignores the
    /// signal, then pauses forever — only SIGKILL can reap it.
    private static let harnessSource = """
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <signal.h>

    static void ignore_term(int sig) { (void)sig; /* deliberately ignore SIGTERM */ }

    int main(int argc, char **argv) {
        if (argc < 2) return 1;
        signal(SIGTERM, ignore_term);
        FILE *f = fopen(argv[1], "w");
        if (f) { fprintf(f, "%d\\n", (int)getpid()); fclose(f); }
        for (;;) pause();
    }
    """

    @Test("FIX6: SIGTERM-ignoring child is SIGKILLed, second-wait reaped, then stopped")
    @MainActor
    func sigtermIgnoringChildCleanup() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-fix6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceURL = scratch.appendingPathComponent("fix6_harness.c")
        try Self.harnessSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        let harnessURL = scratch.appendingPathComponent("fix6_harness")
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = [sourceURL.path, "-o", harnessURL.path]
        try clang.run()
        clang.waitUntilExit()
        #expect(clang.terminationStatus == 0, "clang must compile the C fixture")
        guard clang.terminationStatus == 0 else { return }

        let pidFile = scratch.appendingPathComponent("pid.txt").path

        let prefixRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
            .appendingPathComponent("ms-u1r18-fix6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: prefixRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            SessionReceiptStore().remove(prefix: prefixRoot)
            try? FileManager.default.removeItem(at: prefixRoot)
        }

        let supervisor = GameSessionSupervisor(windowProvider: Fix6EmptyWindowProvider())
        let plan = LaunchPlan(
            runtimeExecutable: harnessURL,
            arguments: [pidFile],
            mode: .supervisedSession
        )
        _ = try await supervisor.launch(
            plan: plan,
            runtimeControl: Fix6CleanupWineRuntime(),
            prefixRoot: prefixRoot,
            recipeID: "cloverpit",
            runtimeID: "ms-u1r18-fix6",
            purpose: .game
        )

        guard let childPID = Self.readPid(pidFile, timeout: 15) else {
            try? await supervisor.forceStop()
            return
        }
        #expect(Self.sysctlStatus(childPID) >= 0, "SIGTERM-ignoring child must be alive before cleanup")

        // forceStop drives the real transaction: SIGTERM (ignored) → bounded
        // wait timeout → SIGKILL → second reap-confirm wait → discard →
        // wineserver confirm → lock release → stopped.
        try await supervisor.forceStop()

        #expect(supervisor.state == .stopped, "cleanup must reach .stopped")
        #expect(Self.waitGone(pid: childPID, timeout: 10), "SIGTERM-ignoring child must be reaped via SIGKILL")
    }

    // MARK: - Fixture helpers

    nonisolated private static func readPid(_ path: String, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            usleep(100_000)
        }
        return nil
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

    nonisolated private static func waitGone(pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sysctlStatus(pid) < 0 { return true }
            usleep(100_000)
        }
        return sysctlStatus(pid) < 0
    }
}
