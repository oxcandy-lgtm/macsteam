import Testing
import Foundation
@testable import MacSteam

@MainActor
struct UltimateLaunchSemanticsTests {
    let testWineURL = URL(fileURLWithPath: "/usr/bin/wine")
    let testSteamURL = URL(fileURLWithPath: "/Applications/steam.exe")
    let testPrefixURL = URL(fileURLWithPath: "/tmp/test-prefix")
    let testRuntimeURL = URL(fileURLWithPath: "/usr/lib/wine")

    // MARK: - Render profiles

    private static let testRenderArgs = ["-cef-enable-gpu", "-no-cef-sandbox"]

    @Test("Steam plan includes render profile args")
    func steamPlan_includesRenderArgs() {
        let env = ["WINEPREFIX": testPrefixURL.path]
        let coordinator = UltimateSetupCoordinator()
        let plan = coordinator.makeSteamSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: Self.testRenderArgs
        )
        for arg in Self.testRenderArgs {
            #expect(plan.arguments.contains(arg), "Missing render arg: \(arg)")
        }
    }

    @Test("CloverPit plan includes render profile args")
    func cloverPitPlan_includesRenderArgs() {
        let env = ["WINEPREFIX": testPrefixURL.path]
        let coordinator = UltimateSetupCoordinator()
        let plan = coordinator.makeCloverPitSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: Self.testRenderArgs
        )
        for arg in Self.testRenderArgs {
            #expect(plan.arguments.contains(arg), "Missing render arg: \(arg)")
        }
    }

    @Test("Steam plan does not include -applaunch")
    func steamPlan_noAppLaunch() {
        let env = ["WINEPREFIX": testPrefixURL.path]
        let coordinator = UltimateSetupCoordinator()
        let plan = coordinator.makeSteamSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: []
        )
        #expect(!plan.arguments.contains("-applaunch"))
    }

    @Test("CloverPit plan includes app ID 3314790 and game flags")
    func cloverPitPlan_includesGameFlags() {
        let env = ["WINEPREFIX": testPrefixURL.path]
        let coordinator = UltimateSetupCoordinator()
        let plan = coordinator.makeCloverPitSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: []
        )
        #expect(plan.arguments.contains("3314790"))
        #expect(plan.arguments.contains("-popupwindow"))
        #expect(plan.arguments.contains("-screen-fullscreen"))
        #expect(plan.arguments.contains("0"))
    }

    @Test("both plans use supervisedSession mode")
    func bothPlans_supervisedSession() {
        let env = ["WINEPREFIX": testPrefixURL.path]
        let coordinator = UltimateSetupCoordinator()
        let steamPlan = coordinator.makeSteamSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: []
        )
        let gamePlan = coordinator.makeCloverPitSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: []
        )
        #expect(steamPlan.mode == .supervisedSession)
        #expect(gamePlan.mode == .supervisedSession)
    }

    @Test("both plans use canonical prefix working directory")
    func bothPlans_canonicalPrefix() {
        let env = ["WINEPREFIX": testPrefixURL.path]
        let coordinator = UltimateSetupCoordinator()
        let steamPlan = coordinator.makeSteamSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: []
        )
        let gamePlan = coordinator.makeCloverPitSessionPlan(
            wineURL: testWineURL, steamURL: testSteamURL,
            prefixURL: testPrefixURL, environment: env,
            renderArguments: []
        )
        #expect(steamPlan.workingDirectory == testPrefixURL)
        #expect(gamePlan.workingDirectory == testPrefixURL)
    }
}

@MainActor
struct SessionModeValidationTests {
    let testRuntimeURL = URL(fileURLWithPath: "/usr/lib/wine")

    @Test("supervisedSession plan passes validation")
    func supervisedSession_valid() throws {
        let plan = LaunchPlan(runtimeExecutable: testRuntimeURL, arguments: [], mode: .supervisedSession)
        try GameSessionSupervisor.validateSessionPlan(plan)
    }

    @Test("waitForExit plan fails validation")
    func waitForExit_invalid() {
        let plan = LaunchPlan(runtimeExecutable: testRuntimeURL, arguments: [], mode: .waitForExit)
        #expect(throws: (any Error).self) {
            try GameSessionSupervisor.validateSessionPlan(plan)
        }
    }

    @Test("detached plan fails validation")
    func detached_invalid() {
        let plan = LaunchPlan(runtimeExecutable: testRuntimeURL, arguments: [], mode: .detached)
        #expect(throws: (any Error).self) {
            try GameSessionSupervisor.validateSessionPlan(plan)
        }
    }
}
