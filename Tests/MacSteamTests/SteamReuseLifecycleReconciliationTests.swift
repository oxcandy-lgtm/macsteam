// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - U1R18-R13-ACCEPTANCE3-FIX1 regression tests
//
// Steam-ready is NEVER claimed from a stale lifecycle flag or the prefix
// signature alone. Every production path routes through the single
// reconciliation authority `reconcileSteamInstallStateFromCurrentPrefix()`,
// which is a pure function of the CURRENT canonical prefix payload:
//
//   - regular non-empty steam.exe       → .verifiedComplete, ready
//   - zero-byte / invalid / missing exe → .absent, not ready
//   - interrupted-hold file present     → .interrupted, not ready
//
// These tests build REAL filesystem fixtures and drive the PRODUCTION
// `createPrefix()` acquisition router + reconciliation so the navigation
// proof (filesystem → reconciliation → verifiedComplete → completion map →
// reducer transition) holds end to end.

@MainActor
struct SteamReuseLifecycleReconciliationTests {

    // MARK: - Filesystem helpers

    private func makeScratchRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-recon-\(UUID().uuidString)")
    }

    /// Create a valid Wine prefix fixture at `root/<name>` with the same
    /// structure the production helper uses for acquisition.
    @discardableResult
    private func createValidPrefix(at root: URL, name: String, withSteam: Bool = true) -> URL {
        let fm = FileManager.default
        let prefixURL = root.appendingPathComponent(name)
        let driveC = prefixURL.appendingPathComponent("drive_c")
        let dosdevices = prefixURL.appendingPathComponent("dosdevices")
        let steamDir = driveC.appendingPathComponent("Program Files (x86)/Steam")

        try! fm.createDirectory(at: driveC, withIntermediateDirectories: true)
        try! fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try! fm.createDirectory(at: driveC.appendingPathComponent("users"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)

        try! "reg".write(to: prefixURL.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try! "reg".write(to: prefixURL.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        let cLink = dosdevices.appendingPathComponent("c:")
        try! fm.createSymbolicLink(atPath: cLink.path, withDestinationPath: "../drive_c")

        if withSteam {
            try! fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
            let steamExe = steamDir.appendingPathComponent("steam.exe")
            try! "MZ-steam-binary".write(to: steamExe, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamExe.path)
        }

        return prefixURL
    }

    /// Create a coordinator whose PrefixManager resolves the scratch root, so
    /// production `createPrefix()` runs against the fixture.
    private func makeCoordinator(scratch: URL) -> UltimateSetupCoordinator {
        let prefixManager = PrefixManager(prefixesRootOverride: scratch)
        return UltimateSetupCoordinator(prefixManager: prefixManager)
    }

    /// Select a MockRuntime that passes the recipe capability gate
    /// (windows-process + isolated-prefix static; steam-client from a
    /// healthy real-load probe), so `createPrefix()` has an active runtime.
    private func selectMockRuntime(on coordinator: UltimateSetupCoordinator) {
        coordinator.setRealLoadHealthyForTesting(true)
        let candidate = RuntimeCandidate(
            id: "mock-wine-test",
            displayName: "Mock Wine (test)",
            runtimeType: .importedWine,
            url: URL(fileURLWithPath: "/tmp/fake-runtime"),
            inspection: RuntimeInspection(
                runtimeID: "mock-wine",
                isUsable: true,
                capabilities: [.windowsProcess, .isolatedPrefix]
            ),
            runtime: MockRuntime()
        )
        coordinator.selectCandidateForTesting(candidate)
        #expect(coordinator.state == .runtimeReady)
    }

    // MARK: - existing_canonical_valid_steam

    @Test("existing canonical prefix with valid steam.exe → steamReady via reconciliation")
    func existingCanonical_validSteam_steamReady() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        selectMockRuntime(on: coordinator)

        await coordinator.createPrefix()

        #expect(coordinator.state == .steamReady)
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)
        #expect(coordinator.steamInspection?.steamInstalled == true)
        #expect(coordinator.steamInspection != .notFound)
        // Proof that steam-ready was earned through reconciliation, not a
        // signature-side-effect: the completion map reflects the lifecycle.
        #expect(coordinator.computePageCompletion()[.steamClient] == true)
    }

    @Test("production navigation chain: filesystem → reconciliation → completion map → reducer")
    func productionNavigationChain_transitionAdmitted() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        selectMockRuntime(on: coordinator)

        await coordinator.createPrefix()
        #expect(coordinator.state == .steamReady)
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)

        // Every upstream page must be complete so the reducer admits the
        // transitions. The completion map comes from the production authority
        // computePageCompletion() — never a hand-built map.
        let completion = coordinator.computePageCompletion()
        #expect(completion[.runtime] == true)
        #expect(completion[.environment] == true)
        #expect(completion[.steamInstaller] == true)
        #expect(completion[.steamClient] == true)

        // No page seeding: drive the real reducer from the initial .runtime
        // position through every production gateway into Steam client.
        await coordinator.send(.next)
        #expect(coordinator.currentPage == .environment)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .steamInstaller)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .steamClient)
        #expect(coordinator.lastNavigationResult?.accepted == true)

        await coordinator.send(.next)
        #expect(coordinator.currentPage == .cloverPit)
        #expect(coordinator.lastNavigationResult?.accepted == true)
    }

    // MARK: - adopted_prefix_valid_steam

    @Test("adopted prefix with valid steam.exe → steamReady via reconciliation")
    func adoptedPrefix_validSteam_steamReady() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // No canonical `cloverpit` prefix → acquisition adopts the sole valid
        // Steam-bearing prefix under the managed root.
        createValidPrefix(at: scratch, name: "ExistingSteamInstall", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        selectMockRuntime(on: coordinator)

        await coordinator.createPrefix()

        #expect(coordinator.state == .steamReady)
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)
        #expect(coordinator.steamInspection?.steamInstalled == true)
        #expect(coordinator.computePageCompletion()[.steamClient] == true)
    }

    // MARK: - recheck_valid_install

    @Test("recheckSteam routes through reconciliation for a valid install")
    func recheckSteam_validInstall_steamReady() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let layoutRoot = createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        selectMockRuntime(on: coordinator)
        await coordinator.createPrefix()
        #expect(coordinator.state == .steamReady)

        // Re-check re-derives ready from the same single authority.
        await coordinator.recheckSteam()
        #expect(coordinator.state == .steamReady)
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)
        #expect(layoutRoot.path == coordinator.prefixLayout?.root.path)
    }

    // MARK: - missing_steam

    @Test("existing prefix without steam.exe → NOT steamReady, lifecycle absent")
    func missingSteam_notSteamReady() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        createValidPrefix(at: scratch, name: "cloverpit", withSteam: false)

        let coordinator = makeCoordinator(scratch: scratch)
        selectMockRuntime(on: coordinator)

        await coordinator.createPrefix()

        #expect(coordinator.state != .steamReady)
        #expect(coordinator.steamInstallLifecycle == .absent)
        #expect(coordinator.steamInspection?.steamInstalled == false)
        #expect(coordinator.computePageCompletion()[.steamClient] == false)
    }

    @Test("missing steam → reconcile reports absent, not ready, no verifiedComplete")
    func missingSteam_reconciliationAbsent() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixURL = createValidPrefix(at: scratch, name: "cloverpit", withSteam: false)

        let coordinator = makeCoordinator(scratch: scratch)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixURL)

        let reconciliation = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(reconciliation.lifecycle == .absent)
        #expect(reconciliation.ready == false)
        #expect(reconciliation.steamInstalled == false)
        #expect(reconciliation.interruptedHoldPresent == false)
        #expect(coordinator.steamInstallLifecycle == .absent)
        #expect(coordinator.steamInspection == .notFound)
    }

    // MARK: - zero_byte_steam

    @Test("zero-byte steam.exe present in signature but payload rejected → NOT ready")
    func zeroByteSteam_payloadRejects() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixURL = createValidPrefix(at: scratch, name: "cloverpit", withSteam: false)

        // Signature claims steam.exe (executable bit set) but the payload is
        // an empty regular file → the reconciliation authority must reject.
        let steamExe = prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try! FileManager.default.createDirectory(at: steamExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data().write(to: steamExe)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamExe.path)
        #expect(prefixURL.appendingPathComponent("drive_c").appendingPathComponent("Program Files (x86)/Steam").appendingPathComponent("steam.exe").path == steamExe.path)
        #expect(FileManager.default.isExecutableFile(atPath: steamExe.path))

        let coordinator = makeCoordinator(scratch: scratch)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixURL)

        let reconciliation = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(reconciliation.lifecycle == .absent)
        #expect(reconciliation.ready == false)
        #expect(reconciliation.steamInstalled == false)
        #expect(coordinator.steamInspection == .notFound)
        #expect(coordinator.computePageCompletion()[.steamClient] == false)
    }

    @Test("zero-byte steam.exe via production createPrefix → NOT steamReady")
    func zeroByteSteam_productionNotSteamReady() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixURL = createValidPrefix(at: scratch, name: "cloverpit", withSteam: false)

        let steamExe = prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try! FileManager.default.createDirectory(at: steamExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data().write(to: steamExe)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamExe.path)

        let coordinator = makeCoordinator(scratch: scratch)
        selectMockRuntime(on: coordinator)

        await coordinator.createPrefix()

        #expect(coordinator.state != .steamReady)
        #expect(coordinator.steamInstallLifecycle != .verifiedComplete)
        if case .steamInstallationFailed = coordinator.error {
            // Expected: signature claimed steam.exe but payload rejected.
        } else {
            Issue.record("expected steamInstallationFailed error, got \(String(describing: coordinator.error))")
        }
    }

    // MARK: - interrupted_hold

    @Test("interrupted-hold file → interrupted lifecycle, NOT ready")
    func interruptedHold_reconciliationInterrupted() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixURL = createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let holdFile = prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe.macsteam-install-hold")
        try! "hold".write(to: holdFile, atomically: true, encoding: .utf8)

        let coordinator = makeCoordinator(scratch: scratch)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixURL)

        let reconciliation = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(reconciliation.lifecycle == .interrupted)
        #expect(reconciliation.ready == false)
        #expect(reconciliation.interruptedHoldPresent == true)
        #expect(reconciliation.projectedSetupState == .steamInstallerVerified)
        #expect(coordinator.steamInstallLifecycle == .interrupted)
    }

    // MARK: - stale_previous_verified_complete_then_missing

    @Test("stale verifiedComplete is NOT reused when the payload is missing")
    func staleVerifiedComplete_notReused() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixURL = createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixURL)

        // First reconciliation earns verifiedComplete from a real payload.
        var reconciliation = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(reconciliation.ready == true)
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)

        // Steam disappears from disk. Reconciliation must DROP readiness.
        try! FileManager.default.removeItem(at: prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        reconciliation = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(reconciliation.ready == false)
        #expect(reconciliation.lifecycle == .absent)
        #expect(coordinator.steamInstallLifecycle == .absent)
        #expect(coordinator.steamInspection == .notFound)
        #expect(coordinator.computePageCompletion()[.steamClient] == false)
    }

    // MARK: - prefix_identity_change

    @Test("prefix identity change clears stale steam truth")
    func prefixIdentityChange_clearsStaleTruth() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixA = createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixA)
        coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)

        // A DIFFERENT canonical prefix root invalidates the previous Steam
        // truth — no stale verifiedComplete crosses the identity change.
        let prefixB = createValidPrefix(at: scratch, name: "other-prefix", withSteam: false)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixB)

        #expect(coordinator.steamInstallLifecycle == .absent)
        #expect(coordinator.steamInspection == nil)

        let reconciliation = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        #expect(reconciliation.ready == false)
        #expect(coordinator.computePageCompletion()[.steamClient] == false)
    }

    // MARK: - repeated_reconciliation idempotent

    @Test("repeated reconciliation is deterministic and idempotent")
    func repeatedReconciliation_idempotent() async {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefixURL = createValidPrefix(at: scratch, name: "cloverpit", withSteam: true)

        let coordinator = makeCoordinator(scratch: scratch)
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixURL)

        let first = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        let second = coordinator.reconcileSteamInstallStateFromCurrentPrefix()
        let third = coordinator.reconcileSteamInstallStateFromCurrentPrefix()

        #expect(first == second)
        #expect(second == third)
        #expect(coordinator.steamInstallLifecycle == .verifiedComplete)
        #expect(coordinator.computePageCompletion()[.steamClient] == true)
    }
}
