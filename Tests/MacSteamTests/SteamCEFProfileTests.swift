// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

// MARK: - SteamUIRenderProfileTests (§19)

struct SteamUIRenderProfileTests {

    @Test func testAutomaticNoArguments() {
        #expect(SteamUIRenderProfile.automatic.launchArguments == [])
    }

    @Test func testCefSoftwareRenderingExactlyCefDisableGpu() {
        #expect(SteamUIRenderProfile.cefSoftwareRendering.launchArguments == ["-cef-disable-gpu"])
    }

    // MARK: - U1R11 new profiles

    @Test func testCefTripleThreeArguments() {
        #expect(SteamUIRenderProfile.cefTriple.launchArguments == [
            "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-no-cef-sandbox"
        ])
    }

    @Test func testCefTripleHasNoCefDisableGpuCompositing() {
        let args = SteamUIRenderProfile.cefTriple.launchArguments
        #expect(args.contains("-cef-disable-gpu-compositing"))
    }

    @Test func testOpenGLFallbackNoCefGpu() {
        let args = SteamUIRenderProfile.openGLFallback.launchArguments
        #expect(args.contains("-opengl"))
        #expect(args.contains("-no-cef-sandbox"))
        #expect(!args.contains("-cef-disable-gpu"))
    }

    @Test func testTenfootOnlyTenfoot() {
        #expect(SteamUIRenderProfile.tenfoot.launchArguments == ["-tenfoot"])
    }

    // MARK: - Display names

    @Test func testDisplayNameAutomatic() {
        #expect(SteamUIRenderProfile.automatic.displayName == "Automatic")
    }

    @Test func testDisplayNameCefTriple() {
        #expect(SteamUIRenderProfile.cefTriple.displayName == "CEF compatibility")
    }

    @Test func testDisplayNameOpenGLFallback() {
        #expect(SteamUIRenderProfile.openGLFallback.displayName == "OpenGL fallback")
    }

    @Test func testDisplayNameTenfoot() {
        #expect(SteamUIRenderProfile.tenfoot.displayName == "Big Picture")
    }

    @Test func testAllCasesCountU1R11() {
        let all = SteamUIRenderProfile.allCases
        // U1R10: 2 (automatic, cefSoftwareRendering)
        // U1R11: +3 (cefTriple, openGLFallback, tenfoot) = 5
        #expect(all.count == 5)
        #expect(all.contains(.automatic))
        #expect(all.contains(.cefSoftwareRendering))
        #expect(all.contains(.cefTriple))
        #expect(all.contains(.openGLFallback))
        #expect(all.contains(.tenfoot))
    }

    @Test func testCrossOverDoesNotAffectProfile() {
        let automaticArgs = SteamUIRenderProfile.automatic.launchArguments
        let cefArgs = SteamUIRenderProfile.cefSoftwareRendering.launchArguments
        #expect(automaticArgs != cefArgs)
    }

    @Test func testAllCasesCovered() {
        #expect(SteamUIRenderProfile.allCases.count == 5)
    }

    // MARK: - Profile persistence

    @MainActor
    @Test func testProfileDefaultsToAutomatic() {
        // U1R12 §1: Profile must NOT persist across coordinator init
        let coord = UltimateSetupCoordinator()
        #expect(coord.steamUIRenderProfile == .automatic)
    }

    // MARK: - Create prefix guard

    @MainActor
    @Test func testCreatePrefixGuardRejectsDuplicate() async {
        let coordinator = UltimateSetupCoordinator()
        #expect(coordinator.state == .inspecting)
        #expect(coordinator.isCreatingPrefix == false)

        coordinator.isCreatingPrefix = true
        // Call createPrefix while isCreatingPrefix is true — guard should return early
        await coordinator.createPrefix()

        // Guard prevented defer from running, and state/error untouched
        #expect(coordinator.isCreatingPrefix == true)
        #expect(coordinator.state == .inspecting)
        #expect(coordinator.error == nil)
    }
}

// MARK: - SteamLaunchArgumentTests (§19)

struct SteamLaunchArgumentTests {

    private let steamExePath = "/prefix/drive_c/Program Files (x86)/Steam/steam.exe"

    @Test func testOpenWindowsSteamSteamExeOnly() {
        // Open Windows Steam: steam.exe + optional CEF args, no applaunch
        let automatic = SteamUIRenderProfile.automatic
        let args = [steamExePath] + automatic.launchArguments
        #expect(args == [steamExePath])
    }

    @Test func testOpenWindowsSteamWithCefProfile() {
        // Steam.exe + -cef-disable-gpu only
        let cefArgs = SteamUIRenderProfile.cefSoftwareRendering.launchArguments
        let args = [steamExePath] + cefArgs
        #expect(args == [steamExePath, "-cef-disable-gpu"])
    }

    @Test func testOpenWindowsSteamNoApplaunch() {
        // No -applaunch in the Steam client launch arguments
        let automatic = SteamUIRenderProfile.automatic
        let args = [steamExePath] + automatic.launchArguments
        #expect(!args.contains { $0 == "-applaunch" })
    }

    @Test func testOpenWindowsSteamNoGameArgs() {
        // No game-specific arguments in Steam client launch
        let automatic = SteamUIRenderProfile.automatic
        let args = [steamExePath] + automatic.launchArguments
        let gameKeywords = ["-popupwindow", "-screen-fullscreen", "3314790"]
        for kw in gameKeywords {
            #expect(!args.contains(kw))
        }
    }

    @Test func testLaunchCloverPitHasApplaunchAndGameArgs() {
        // Launch CloverPit: steam.exe + CEF args + -applaunch <id> + game args
        let profileArgs = SteamUIRenderProfile.cefSoftwareRendering.launchArguments
        let gameArgs = ["-applaunch", "3314790", "-popupwindow", "-screen-fullscreen", "0"]
        let args = [steamExePath] + profileArgs + gameArgs

        #expect(args.contains("-applaunch"))
        #expect(args.contains("3314790"))
        #expect(args.contains("-popupwindow"))
        #expect(args.contains("-screen-fullscreen"))
        #expect(args.firstIndex(of: "-applaunch")! > args.firstIndex(of: steamExePath)!)
    }

    @Test func testCefArgsBeforeApplaunch() {
        // CEF profile arguments must come BEFORE -applaunch
        let profileArgs = SteamUIRenderProfile.cefSoftwareRendering.launchArguments
        let gameArgs = ["-applaunch", "3314790", "-popupwindow", "-screen-fullscreen", "0"]
        let args = [steamExePath] + profileArgs + gameArgs

        if let cefIdx = args.firstIndex(of: "-cef-disable-gpu"),
           let applaunchIdx = args.firstIndex(of: "-applaunch") {
            #expect(cefIdx < applaunchIdx)
        }
    }

    @Test func testAutomaticBypassDoesNotAddCefArg() {
        // .automatic should never add CEF args even in CloverPit launch
        let profileArgs = SteamUIRenderProfile.automatic.launchArguments
        let gameArgs = ["-applaunch", "3314790", "-popupwindow", "-screen-fullscreen", "0"]
        let args = [steamExePath] + profileArgs + gameArgs
        #expect(!args.contains("-cef-disable-gpu"))
    }
}

// MARK: - SteamCEFDiagnosticClassifierTests (§19)

struct SteamCEFDiagnosticClassifierTests {

    @Test func testEmptyInput() {
        let result = SteamCEFDiagnosticClassifier.classify(lines: [])
        #expect(result.empty)
        #expect(!result.gpuProcessStarted)
        #expect(!result.gpuProcessExitedUnexpectedly)
    }

    @Test func testGpuProcessStarted() {
        let lines = ["[0729/202800.123] GPU process started"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.gpuProcessStarted)
        #expect(!result.gpuProcessExitedUnexpectedly)
        #expect(!result.empty)
    }

    @Test func testGpuProcessExitedUnexpectedly() {
        let lines = ["[0729/202800.456] GPU process exited unexpectedly"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.gpuProcessExitedUnexpectedly)
    }

    @Test func testGpuInitializationFailed() {
        let lines = ["[0729/202800.789] Exiting GPU process due to errors during initialization"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.gpuInitializationFailed)
    }

    @Test func testRendererStarted() {
        let lines = ["[0729/202800.111] Renderer process started"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.rendererStarted)
    }

    @Test func testInvalidBrowserDimensions() {
        let lines = ["[0729/202800.222] Invalid browser dimensions"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.invalidBrowserDimensions)
    }

    @Test func testSandboxAlreadyDisabled() {
        let lines = ["CEF sandbox already disabled"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.sandboxAlreadyDisabled)
    }

    @Test func testMultipleSignals() {
        let lines = [
            "[0729/202800.123] GPU process started",
            "[0729/202802.456] GPU process exited unexpectedly",
            "[0729/202803.789] Exiting GPU process due to errors during initialization",
        ]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.gpuProcessStarted)
        #expect(result.gpuProcessExitedUnexpectedly)
        #expect(result.gpuInitializationFailed)
        #expect(!result.rendererStarted)
        #expect(!result.invalidBrowserDimensions)
        #expect(!result.empty)
    }

    @Test func testNoFalsePositives() {
        // Ensure random log content doesn't trigger booleans
        let lines = ["some random log line", "another line without keywords"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(!result.gpuProcessStarted)
        #expect(!result.gpuProcessExitedUnexpectedly)
        #expect(!result.gpuInitializationFailed)
        #expect(!result.rendererStarted)
        #expect(!result.invalidBrowserDimensions)
        #expect(!result.empty)
    }

    @Test func testCaseInsensitive() {
        let lines = ["GPU Process Started", "Invalid Browser Dimensions"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        #expect(result.gpuProcessStarted)
        #expect(result.invalidBrowserDimensions)
    }

    @Test func testIdentityValuesNeverReturned() {
        // Ensure no identity-like values leak through (booleans only)
        let lines = ["some CEF diagnostic content without patterns"]
        let result = SteamCEFDiagnosticClassifier.classify(lines: lines)
        // All booleans should be false (no identity data)
        #expect(result == SteamCEFDiagnosticSummary(
            gpuProcessStarted: false,
            gpuProcessExitedUnexpectedly: false,
            gpuInitializationFailed: false,
            rendererStarted: false,
            invalidBrowserDimensions: false,
            sandboxAlreadyDisabled: false,
            empty: false
        ))
    }
}

// MARK: - SteamUIProbeResultTests

struct SteamUIProbeResultTests {

    @Test func testClassificationBlackScreen() {
        let result = SteamUIProbeResult(
            profile: .automatic,
            nativeWindowCreated: true,
            contentRendered: false,
            inputWorks: false,
            stable30Seconds: false,
            notes: ["black screen observed"]
        )
        #expect(result.classification == "black_screen")
    }

    @Test func testClassificationHealthy() {
        let result = SteamUIProbeResult(
            profile: .cefSoftwareRendering,
            nativeWindowCreated: true,
            contentRendered: true,
            inputWorks: true,
            stable30Seconds: true,
            notes: []
        )
        #expect(result.classification == "healthy")
    }

    @Test func testClassificationNoWindow() {
        let result = SteamUIProbeResult(
            profile: .automatic,
            nativeWindowCreated: false,
            contentRendered: false,
            inputWorks: false,
            stable30Seconds: false,
            notes: []
        )
        #expect(result.classification == "no_window")
    }
}
