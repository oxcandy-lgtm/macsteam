// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

// MARK: - U1R18 preflight classifier (pure — deterministic)

struct WineRealLoadProbeClassifierTests {

    @Test("healthy output with Microsoft Windows is classified healthy")
    func healthy() {
        let status = WineRealLoadProbe.classify(
            stdout: "Microsoft Windows 10.0.19045\n",
            stderr: "",
            exitCode: 0
        )
        #expect(status == .healthy)
    }

    @Test("FreeType catastrophe is detected even on exit code 0")
    func freeTypeCatastrophe_onZeroExit() {
        let status = WineRealLoadProbe.classify(
            stdout: "",
            stderr: "Wine cannot find the FreeType font library...\n",
            exitCode: 0
        )
        #expect(status == .dependencyMissing)
    }

    @Test("non-zero exit without marker is launchFailed")
    func nonZeroExit_isLaunchFailed() {
        let status = WineRealLoadProbe.classify(
            stdout: "",
            stderr: "some other error",
            exitCode: 1
        )
        #expect(status == .launchFailed)
    }

    @Test("nil exit code (timeout) fails closed as timedOut")
    func nilExit_isTimedOut() {
        let status = WineRealLoadProbe.classify(
            stdout: "",
            stderr: "",
            exitCode: nil
        )
        #expect(status == .timedOut)
    }

    @Test("windowsVersion extraction from cmd /c ver")
    func windowsVersionParsing() {
        #expect(WineRealLoadProbe.windowsVersion(from: "Microsoft Windows 10.0.19045\n") == "Microsoft Windows 10.0.19045")
        #expect(WineRealLoadProbe.windowsVersion(from: "") == nil)
    }
}

// MARK: - U1R18 capability gate (deterministic)

struct RuntimeCapabilityGateTests {

    @Test("recipe strings map to capability bits")
    func stringMapping() {
        #expect(RuntimeCapabilityGate.capability(from: "windows-process") == .windowsProcess)
        #expect(RuntimeCapabilityGate.capability(from: "steam-client") == .steamClient)
        #expect(RuntimeCapabilityGate.capability(from: "isolated-prefix") == .isolatedPrefix)
        #expect(RuntimeCapabilityGate.capability(from: "bogus") == nil)
    }

    @Test("required set builds from recipe strings")
    func requiredFromStrings() {
        let required = RuntimeCapabilityGate.required(
            from: ["windows-process", "steam-client", "isolated-prefix"]
        )
        #expect(required == [.windowsProcess, .steamClient, .isolatedPrefix])
    }

    @Test("steam-client is proven by healthy real-load only")
    func steamClientProvenByRealLoad() {
        let staticCaps: RuntimeCapabilities = [.windowsProcess, .isolatedPrefix]
        let withoutProbe = RuntimeCapabilityGate.effectiveCapabilities(
            staticCaps: staticCaps,
            realLoadHealthy: false
        )
        #expect(!withoutProbe.contains(.steamClient))
        #expect(RuntimeCapabilityGate.isSatisfied(
            required: [.windowsProcess, .steamClient, .isolatedPrefix],
            effective: withoutProbe
        ) == false)

        let withProbe = RuntimeCapabilityGate.effectiveCapabilities(
            staticCaps: staticCaps,
            realLoadHealthy: true
        )
        #expect(withProbe.contains(.steamClient))
        #expect(RuntimeCapabilityGate.isSatisfied(
            required: [.windowsProcess, .steamClient, .isolatedPrefix],
            effective: withProbe
        ))
    }

    @Test("missing capability names are deterministic")
    func missingNames() {
        let missing = RuntimeCapabilityGate.missingCapabilityNames(
            required: [.windowsProcess, .steamClient, .isolatedPrefix],
            effective: [.windowsProcess, .isolatedPrefix]
        )
        #expect(missing == ["steam-client"])
    }
}

// MARK: - U1R18 coordinator wiring (capability gate on selection)

@MainActor
struct CoordinatorCapabilityGateTests {

    @Test("selection rejects runtime missing recipe-required capability")
    func rejectsMissingCapability() {
        let coordinator = UltimateSetupCoordinator()
        // No real-load proof → steam-client missing → gate rejects.
        let candidate = RuntimeCandidate(
            id: "imported-wine-test",
            displayName: "Imported Wine (test)",
            runtimeType: .importedWine,
            url: URL(fileURLWithPath: "/tmp/fake-runtime"),
            inspection: RuntimeInspection(
                runtimeID: "imported-wine",
                isUsable: true,
                capabilities: [.windowsProcess, .isolatedPrefix]
            ),
            runtime: nil
        )
        coordinator.selectCandidateForTesting(candidate)
        #expect(coordinator.state == .runtimeInvalid)
        if case .runtimeInspectionFailed(let detail) = coordinator.error {
            #expect(detail.contains("steam-client"))
        } else {
            Issue.record("expected runtimeInspectionFailed error, got \(String(describing: coordinator.error))")
        }
    }

    @Test("selection accepts runtime after healthy real-load proves steam-client")
    func acceptsAfterHealthyRealLoad() {
        let coordinator = UltimateSetupCoordinator()
        coordinator.setRealLoadHealthyForTesting(true)
        let candidate = RuntimeCandidate(
            id: "imported-wine-test",
            displayName: "Imported Wine (test)",
            runtimeType: .importedWine,
            url: URL(fileURLWithPath: "/tmp/fake-runtime"),
            inspection: RuntimeInspection(
                runtimeID: "imported-wine",
                isUsable: true,
                capabilities: [.windowsProcess, .isolatedPrefix]
            ),
            runtime: nil
        )
        coordinator.selectCandidateForTesting(candidate)
        #expect(coordinator.state == .runtimeReady)
    }
}

// MARK: - U1R18 wineboot exactly-once decision

struct WinebootExactlyOnceTests {
    @Test("fresh prefix with no steam and no signature requires wineboot")
    func freshPrefix_runsWineboot() {
        // steam.exe absent + signature invalid → wineboot must run.
        let skip = UltimateSetupCoordinator.shouldSkipWinebootForExistingPrefix(
            steamExePresent: false,
            signatureValid: false
        )
        #expect(skip == false)
    }

    @Test("steam-present prefix short-circuits before wineboot")
    func steamPresent_skipsViaSteamReady() {
        // steam.exe present → the earlier steamReady branch returns first;
        // the reuse decision itself must not claim a wineboot run.
        let skip = UltimateSetupCoordinator.shouldSkipWinebootForExistingPrefix(
            steamExePresent: true,
            signatureValid: true
        )
        #expect(skip == false)
    }

    @Test("initialized prefix without steam is reused — wineboot not duplicated")
    func initializedPrefix_reusedWithoutWineboot() {
        // Valid signature proves wineboot already ran once.
        let skip = UltimateSetupCoordinator.shouldSkipWinebootForExistingPrefix(
            steamExePresent: false,
            signatureValid: true
        )
        #expect(skip == true)
    }
}

// MARK: - U1R18 R1: Steam visibility is measured from the WindowServer

struct SteamClientVisibilityMappingTests {
    @Test("visible session maps to runningVisible")
    func visible_session_mapsToRunningVisible() {
        #expect(SteamClientState(sessionState: .runningVisible) == .runningVisible)
    }

    @Test("hidden session maps to runningHidden")
    func hidden_session_mapsToRunningHidden() {
        #expect(SteamClientState(sessionState: .runningHidden) == .runningHidden)
    }

    @Test("unknown session maps to launching — never guessed visible")
    func unknown_session_mapsToLaunching() {
        // Process alive but WindowServer has not confirmed a window yet.
        #expect(SteamClientState(sessionState: .runningUnknown) == .launching)
        #expect(SteamClientState(sessionState: .launching) == .launching)
    }

    @Test("stopped and idle map to stopped")
    func stopped_mapsToStopped() {
        #expect(SteamClientState(sessionState: .stopped) == .stopped)
        #expect(SteamClientState(sessionState: .idle) == .stopped)
    }

    @Test("recovery and failure surface as recoveryRequired")
    func recovery_mapsToRecoveryRequired() {
        #expect(SteamClientState(sessionState: .recoveryRequired("boom")) == .recoveryRequired("boom"))
        #expect(SteamClientState(sessionState: .failed("boom")) == .recoveryRequired("boom"))
    }

    @Test("stopping maps to stopping")
    func stopping_mapsToStopping() {
        #expect(SteamClientState(sessionState: .stopping) == .stopping)
    }
}

// MARK: - U1R18 R1: Steam launch is non-duplicate (isLaunchingSteam guard)

@MainActor
struct SteamLaunchDedupGuardTests {

    @Test("second launch request while launching is ignored")
    func duplicateLaunchRequest_ignored() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.isLaunchingSteam = true
        await coordinator.launchWindowsSteam()

        // Guard returns before any reconcile/launch work: flag untouched,
        // no error, no state mutation.
        #expect(coordinator.isLaunchingSteam == true)
        #expect(coordinator.error == nil)
    }

    @Test("incomplete installation blocks launch")
    func incompleteInstallation_blocksLaunch() async {
        let coordinator = UltimateSetupCoordinator()
        coordinator.steamInstallLifecycle = .installing
        await coordinator.launchWindowsSteam()

        // Blocked: installation incomplete → steamInstallationPending + error
        #expect(coordinator.state == .steamInstallationPending)
        #expect(coordinator.steamClientState == .stopped)
    }
}

// MARK: - U1R18 R1: teardown cannot hang (waitForExit exactly-once resume)

struct WaitForExitContinuationLeakTests {

    @Test("timeout returns before process exits — no continuation leak")
    func timeoutReturnsBeforeExit() async throws {
        let supervisor = ProcessSupervisor()
        // /bin/sleep 30 outlives a 1-second timeout.
        let handle = try await supervisor.launch(plan: LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            mode: .supervisedSession
        ))
        #expect(handle.isValid)

        let start = ContinuousClock.now
        let outcome = await supervisor.waitForExit(handle, timeout: .seconds(1))
        let elapsed = start.duration(to: ContinuousClock.now)

        // Must return .timedOut promptly (not hang until the 30s sleep ends).
        #expect(outcome == .timedOut)
        #expect(elapsed < .seconds(5))

        // The process is still alive — terminate it. SIGTERM on /bin/sleep
        // reports the signal number (15) as termination status.
        await supervisor.requestTerminate(handle)
        let exit = await supervisor.waitForExit(handle, timeout: .seconds(10))
        #expect(exit == .exited(15))
    }

    @Test("second waiter after timeout does not crash on late exit")
    func lateExitAfterTimeoutDoesNotCrash() async throws {
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.launch(plan: LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            mode: .supervisedSession
        ))
        #expect(handle.isValid)

        let first = await supervisor.waitForExit(handle, timeout: .milliseconds(300))
        #expect(first == .timedOut)

        // Force-kill; the termination handler must not resume a completed continuation.
        try await supervisor.requestForceKill(handle)
        let second = await supervisor.waitForExit(handle, timeout: .seconds(10))
        #expect(second != .timedOut)
    }
}
