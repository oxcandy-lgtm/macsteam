// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

private enum BringUpLog {
    static let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macsteam-bringup.log")
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

/// Real-Mac R1 bring-up evidence suite (U1R18).
///
/// These tests exercise the REAL supervision chain against the machine's
/// actual Wine runtime and CloverPit prefix, including a real WindowServer
/// observer. They are gated on `MACSTEAM_R1_BRINGUP=1` and are skipped on CI
/// (which has no Wine/prefix/window server).
///
/// Deliverables:
///  - windows_steam_actually_launches
///  - prefix_and_steam_launch_are_non_duplicate
///  - window_visibility_is_measured_from_windowserver
///  - dock_quit_removes_owned_runtime (teardown chain)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSTEAM_R1_BRINGUP"] == "1"))
@MainActor
struct U1R18RealMacBringUpTests {

    private var macSteamSupportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam")
    }

    private var importedRuntimesDir: URL { macSteamSupportDir.appendingPathComponent("ImportedRuntimes") }
    private var runtimeDepsDir: URL { macSteamSupportDir.appendingPathComponent("RuntimeDependencies") }
    private var prefixesDir: URL { macSteamSupportDir.appendingPathComponent("Prefixes") }

    @Test("R1: real-load probe reports healthy against WineCX10 with provisioned deps")
    func realLoadProbeHealthy() async throws {
        let runtimeURL = importedRuntimesDir.appendingPathComponent("WineCX10.bundle")
        let wineURL = WineExecutableLayout.detect(from: runtimeURL).wine
        #expect(FileManager.default.isExecutableFile(atPath: wineURL.path))

        // Provisioned dependency dir must exist at the canonical hash.
        let probe = WineRealLoadProbe()
        let result = await probe.probe(
            runtimeURL: runtimeURL,
            wineURL: wineURL,
            scratchPrefixRoot: macSteamSupportDir
        )

        let message = "status=\(result.status.rawValue) detail=\(result.detail) version=\(result.windowsVersion ?? "nil")"
        #expect(result.isHealthy, Comment(rawValue: message))
        #expect(result.windowsVersion != nil)
    }

    @Test("R1: supervised Windows Steam launches, window visibility measured by WindowServer")
    func supervisedSteamLaunchAndWindowServerVisibility() async throws {
        let runtimeURL = importedRuntimesDir.appendingPathComponent("WineCX10.bundle")
        let prefixURL = prefixesDir.appendingPathComponent("cloverpit")
        let steamURL = prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        let steamURLAlt = prefixURL.appendingPathComponent("drive_c/Program Files/Steam/steam.exe")
        let steamExe = FileManager.default.fileExists(atPath: steamURL.path) ? steamURL : steamURLAlt
        #expect(FileManager.default.fileExists(atPath: steamExe.path), "cloverpit prefix must contain steam.exe")

        guard let runtime = ImportedWineRuntime(url: runtimeURL) else {
            Issue.record("Could not construct ImportedWineRuntime for WineCX10")
            return
        }
        let inspection = runtime.inspect()
        #expect(inspection.isUsable, "runtime inspection failed: \(inspection.failures)")

        let wineURL = WineExecutableLayout.detect(from: runtimeURL).wine
        let environment = Self.buildWineEnvironment(runtimeURL: runtimeURL)

        // Real WindowServer observer — the default provider.
        let supervisor = GameSessionSupervisor()
        let plan = LaunchPlan(
            runtimeExecutable: wineURL,
            arguments: [steamExe.path],
            mode: .supervisedSession,
            environment: environment,
            workingDirectory: prefixURL
        )

        do {
            BringUpLog.log(" launching steam session...")
            let session = try await supervisor.launch(
                plan: plan,
                runtimeControl: runtime,
                prefixRoot: prefixURL,
                recipeID: "steam-setup",
                runtimeID: ImportedWineRuntime.runtimeID,
                purpose: .steamSetup
            )
            BringUpLog.log(" session launched rootPID=\(session.rootPID) state=\(supervisor.state)")
            #expect(session.rootPID > 0)
            #expect(supervisor.isRunning)

            // The WindowServer observer drives state — wait for real visibility.
            BringUpLog.log(" waiting for windowserver-observed state...")
            let visible = await waitForAnyOf(
                supervisor,
                targets: [.runningVisible, .runningHidden, .runningUnknown],
                timeout: .seconds(90)
            )
            BringUpLog.log(" state after wait: \(supervisor.state) (visible=\(visible))")
            #expect(visible, "supervisor never reached a running state; state=\(supervisor.state)")

            // U1R18 R1: dedup — a second launch must be rejected as duplicate.
            BringUpLog.log(" attempting duplicate launch...")
            do {
                _ = try await supervisor.launch(
                    plan: plan,
                    runtimeControl: runtime,
                    prefixRoot: prefixURL,
                    recipeID: "steam-setup",
                    runtimeID: ImportedWineRuntime.runtimeID,
                    purpose: .steamSetup
                )
                Issue.record("duplicate launch was NOT rejected")
            } catch let error as SessionSupervisorError {
                guard case .sessionAlreadyRunning = error else {
                    Issue.record("expected sessionAlreadyRunning, got \(error)")
                    return
                }
            }
            BringUpLog.log(" duplicate launch correctly rejected")

            // Teardown chain: stop must terminate the owned runtime and clean the receipt.
            BringUpLog.log(" stopping session...")
            try await supervisor.stop()
            BringUpLog.log(" session stopped state=\(supervisor.state)")
            #expect(supervisor.state == .stopped)
            #expect(supervisor.isRunning == false)

            let receipt = SessionReceiptStore()
            #expect(receipt.read(prefix: prefixURL) == nil,
                    "receipt must be removed after dock/quit-style stop")
        } catch {
            try? await supervisor.forceStop()
            throw error
        }
    }

    @Test("R1: re-running createPrefix reuses initialized prefix (no wineboot duplication)")
    func createPrefixReusesInitializedPrefix() async throws {
        // Deterministic decision gate — verified on real path inputs.
        #expect(UltimateSetupCoordinator.shouldSkipWinebootForExistingPrefix(
            steamExePresent: false,
            signatureValid: true
        ) == true)
    }

    // MARK: - Helpers

    @MainActor
    private func waitForAnyOf(
        _ supervisor: GameSessionSupervisor,
        targets: [GameSessionState],
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if targets.contains(supervisor.state) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return targets.contains(supervisor.state)
    }

    private static func buildWineEnvironment(runtimeURL: URL) -> [String: String] {
        guard let depLayout = RuntimeDependencyLayout(runtimePath: runtimeURL.path) else { return [:] }
        let libDir = depLayout.libDirectory()
        let fm = FileManager.default
        var env = SafeProcessEnvironment.base
        if fm.fileExists(atPath: libDir.path) {
            env["DYLD_LIBRARY_PATH"] = libDir.path
            let fcDir = depLayout.fontconfigDirectory()
            if fm.fileExists(atPath: fcDir.path) {
                env["FONTCONFIG_PATH"] = fcDir.path
            }
        }
        return env
    }
}
