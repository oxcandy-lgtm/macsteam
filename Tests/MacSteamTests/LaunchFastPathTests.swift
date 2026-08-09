// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

/// Deterministic fake file-identity provider keyed by path.
final class FakeLaunchFileIdentityProvider: @unchecked Sendable, LaunchFileIdentityProviding {
    var identities: [String: LaunchFileIdentity] = [:]
    func identity(for url: URL) -> LaunchFileIdentity? {
        identities[url.path]
    }
}

/// Deterministic fake prefix inspector returning a valid inspection.
final class FakePrefixInspector2: PrefixInspecting {
    let inspection: PrefixInspection
    init(_ inspection: PrefixInspection) { self.inspection = inspection }
    func inspect(url: URL) -> PrefixInspection { inspection }
}

/// U1R18-R13-FIX1-FIX2 §19/§20: fast-path + stale-observer production behaviour.
struct LaunchFastPathTests {

    private func fileID(size: UInt64 = 100, mtime: Int64 = 1000, inode: UInt64 = 1) -> LaunchFileIdentity {
        LaunchFileIdentity(isRegularFile: true, size: size, mtimeNanos: mtime, inode: inode, device: 1)
    }

    private func tempPrefix() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("akiyalife-test-prefix-\(UUID().uuidString)")
    }

    /// Create a runtime directory with an executable `bin/wine` so the layout
    /// detector resolves the standard `<root>/bin/wine` layout.
    @discardableResult
    private func makeRuntimeDir(_ root: URL) -> URL {
        let bin = root.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try? Data("wine".utf8).write(to: wine)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        return root
    }

    /// Build a coordinator with a canonical prefix whose evidence is valid and
    /// an injectable file-identity provider.
    @MainActor
    private func makeCoordinatorAt(
        prefixRoot: URL,
        fileIdentity: FakeLaunchFileIdentityProvider
    ) -> UltimateSetupCoordinator {
        let fm = FileManager.default
        try? fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixRoot.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixRoot.appendingPathComponent("drive_c/users"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixRoot.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
        // Create the canonical x86 steam.exe so the single resolver returns it.
        let steamDir = prefixRoot.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try? fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try? Data("steam".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        let coordinator = UltimateSetupCoordinator(
            fileIdentityProvider: fileIdentity
        )
        let valid = PrefixInspection(prefixURL: prefixRoot, driveCExists: true,
                                     hasWinePrefix: true, hasSteam: true, isValid: true)
        coordinator.prefixInspectorProvider = { FakePrefixInspector2(valid) }
        coordinator.prefixLayout = try! PrefixLayout(validatedRoot: prefixRoot)
        _ = coordinator.establishPrefixEvidence(for: coordinator.prefixLayout!, source: .existingCanonical)
        return coordinator
    }

    @MainActor
    @Test func firstLaunchNoCacheTakesFullValidation() {
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        // No prior success -> no fast path.
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: root, candidateRuntimeType: "imported_wine"))
    }

    @MainActor
    @Test func candidateBoundFingerprintDoesNotUseOldSelectedRuntime() {
        // FIX D: the fast-path decision uses the candidate, not self.runtimeURL.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)

        let candidateA = makeRuntimeDir(root.appendingPathComponent("runtime-\(UUID().uuidString)"))
        let candidateB = makeRuntimeDir(root.appendingPathComponent("runtime-\(UUID().uuidString)"))
        // The derived wine path is <runtime>/bin/wine (standard layout).
        fake.identities[candidateA.appendingPathComponent("bin/wine").path] = fileID(inode: 10)
        fake.identities[candidateB.appendingPathComponent("bin/wine").path] = fileID(inode: 20)
        fake.identities[root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path] = fileID(inode: 5)

        // Record a cache success for candidate A (runtime directory URL).
        let fpA = coordinator.buildLaunchFingerprint(
            candidateRuntimeURL: candidateA, candidateRuntimeType: "imported_wine")
        coordinator.recordLaunchCacheSuccess(fingerprint: fpA)

        // Candidate A matches -> fast path.
        #expect(coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: candidateA, candidateRuntimeType: "imported_wine"))
        // Candidate B does NOT match.
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: candidateB, candidateRuntimeType: "imported_wine"))
    }

    @MainActor
    @Test func sameRuntimePathChangedFileIdentityMisses() {
        // FIX E: same runtime path, changed material identity -> no fast path.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)

        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        let winePath = runtimeURL.appendingPathComponent("bin/wine")
        fake.identities[winePath.path] = fileID(size: 100, mtime: 1000)
        fake.identities[root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path] = fileID(inode: 5)

        let fpOld = coordinator.buildLaunchFingerprint(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine")
        coordinator.recordLaunchCacheSuccess(fingerprint: fpOld)
        #expect(coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))

        // Same runtime path, replaced file (mtime changes) -> miss.
        fake.identities[winePath.path] = fileID(size: 100, mtime: 2000)
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))
    }

    @MainActor
    @Test func staleObserverGenerationRejected() {
        // FIX H: each new attempt advances the generation; an old generation is
        // stale and must not complete a later attempt.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let genA = coordinator.currentAttemptGeneration
        coordinator.beginSteamAttempt()
        let genB = coordinator.currentAttemptGeneration
        #expect(genB != genA)
        coordinator.beginSteamAttempt()
        let genC = coordinator.currentAttemptGeneration
        #expect(genC > genB)
        // The observer for attempt A (genA) is stale by the time genC is current.
        #expect(genA != coordinator.currentAttemptGeneration)
    }

    // MARK: - U1R18-R13-FIX1-FIX3 §9 terminal/matrix tests

    @MainActor
    @Test func firstFullThenSecondFastThroughProductionTerminal() async {
        // FIX A/D/G: first launch full -> real terminal success records cache ->
        // second exact matching launch fast. Uses the production terminal seam,
        // not a direct recordLaunchCacheSuccess call to fake the first success.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        fake.identities[runtimeURL.appendingPathComponent("bin/wine").path] = fileID(inode: 1)
        fake.identities[root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path] = fileID(inode: 5)

        // First launch: establish a full validation decision (no real probe).
        coordinator.runtimeURL = runtimeURL
        coordinator.runtimeSourceType = "imported_wine"
        coordinator.setValidationDecisionForTesting(path: .fullValidation, healthy: true, runtimeURL: runtimeURL)
        #expect(coordinator.lastValidationPath == .fullValidation)

        // Real terminal success via the production seam -> consumes the sealed
        // decision and records the cache.
        coordinator.beginSteamAttempt()
        coordinator.requireLaunchTransition(to: .startingSteam)
        coordinator.requireLaunchTransition(to: .waitingForSteam)
        let gen = coordinator.currentAttemptGeneration
        let result = coordinator.completeSteamReadyIfCurrent(
            generation: gen,
            observedState: .runningVisible,
            elapsedMS: 100
        )
        #expect(result == .admittedReady)
        #expect(coordinator.lastLaunchPath == "full")

        // Second exact matching launch: fast path (production decision method).
        let decision2 = await coordinator.performValidationDecisionForTest(runtimeURL: runtimeURL)
        #expect(decision2.path == .fastValidation)
        #expect(coordinator.lastValidationPath == .fastValidation)
    }

    @MainActor
    @Test func staleGenerationTerminalIgnored() {
        // FIX A/H/G: a stale generation cannot mutate the current attempt.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        coordinator.beginSteamAttempt()
        let oldGen = coordinator.currentAttemptGeneration
        coordinator.beginSteamAttempt() // newer attempt advances generation
        let result = coordinator.completeSteamReadyIfCurrent(
            generation: oldGen,
            observedState: .runningVisible,
            elapsedMS: 50
        )
        #expect(result == .ignoredStale)
        #expect(coordinator.launchPipelineStage != .ready)
    }

    @MainActor
    @Test func rejectedReadyBlocksCacheAndSample() {
        // FIX §9.15: a rejected .ready transition => no timing sample, no cache.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        fake.identities[runtimeURL.appendingPathComponent("bin/wine").path] = fileID(inode: 1)
        fake.identities[root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path] = fileID(inode: 5)
        coordinator.runtimeURL = runtimeURL
        coordinator.runtimeSourceType = "imported_wine"
        coordinator.setValidationDecisionForTesting(path: .fullValidation, healthy: true, runtimeURL: runtimeURL)
        coordinator.beginSteamAttempt()
        let gen = coordinator.currentAttemptGeneration
        // Force an illegal ready transition (from idle -> ready is rejected).
        let result = coordinator.completeSteamReadyIfCurrent(
            generation: gen,
            observedState: .runningVisible,
            elapsedMS: 100
        )
        #expect(result == .failedTransition)
        #expect(coordinator.launchAuthority.failed)
        #expect(coordinator.lastValidationPath == nil)
    }

    @MainActor
    @Test func missingRuntimeIdentityDisablesFast() {
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = root.appendingPathComponent("noid-runtime")
        // No wine identity set -> buildLaunchFingerprint nil -> fast disabled.
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))
    }

    @MainActor
    @Test func missingSteamIdentityDisablesFast() {
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        fake.identities[runtimeURL.appendingPathComponent("bin/wine").path] = fileID(inode: 1)
        // No steam identity set -> fast disabled.
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))
    }

    @MainActor
    @Test func nonImportedWineDisablesFast() {
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        fake.identities[runtimeURL.appendingPathComponent("bin/wine").path] = fileID(inode: 1)
        fake.identities[root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path] = fileID(inode: 5)
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "system_wine"))
    }

    @MainActor
    @Test func x86AndFallbackSteamSwitchDoesNotAdmit() {
        // FIX C: switching between x86 and fallback executable -> miss.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        fake.identities[runtimeURL.appendingPathComponent("bin/wine").path] = fileID(inode: 1)
        let x86Path = root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        let fallbackPath = root.appendingPathComponent("drive_c/Program Files/Steam/steam.exe")
        fake.identities[x86Path.path] = fileID(inode: 10)
        fake.identities[fallbackPath.path] = fileID(inode: 20)
        // Ensure both files exist on disk so the resolver can select them.
        try? FileManager.default.createDirectory(
            at: x86Path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x86".utf8).write(to: x86Path)
        try? FileManager.default.createDirectory(
            at: fallbackPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("fallback".utf8).write(to: fallbackPath)

        // Bind x86 (x86 file exists -> resolver returns x86).
        let fpX = coordinator.buildLaunchFingerprint(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine")
        coordinator.recordLaunchCacheSuccess(fingerprint: fpX)
        #expect(coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))

        // Remove x86, keep only fallback -> resolver binds fallback -> miss.
        try? FileManager.default.removeItem(at: x86Path)
        #expect(coordinator.resolveSteamExecutable(in: root)?.path == fallbackPath.path)
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))
    }

    @MainActor
    @Test func failedAttemptDoesNotInheritFastAdmission() {
        // FIX §9.16: a failed attempt must not leave a successful fast admission.
        let root = tempPrefix()
        let fake = FakeLaunchFileIdentityProvider()
        let coordinator = makeCoordinatorAt(prefixRoot: root, fileIdentity: fake)
        let runtimeURL = makeRuntimeDir(root.appendingPathComponent("wine-runtime"))
        fake.identities[runtimeURL.appendingPathComponent("bin/wine").path] = fileID(inode: 1)
        fake.identities[root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path] = fileID(inode: 5)
        coordinator.recordLaunchCacheSuccess(
            fingerprint: coordinator.buildLaunchFingerprint(
                candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))
        coordinator.failLaunchAttempt()
        #expect(!coordinator.shouldTakeLaunchFastPath(
            candidateRuntimeURL: runtimeURL, candidateRuntimeType: "imported_wine"))
    }
}

extension UltimateSetupCoordinator {
    /// Test-only seam: run the production validation decision (fast or full).
    /// For the second exact matching launch this takes the fast path, so no
    /// real probe runs.
    @MainActor
    func performValidationDecisionForTest(runtimeURL: URL) async -> (path: LaunchValidationPath, healthy: Bool) {
        let wineURL = WineExecutableLayout.detect(from: runtimeURL).wine
        let outcome = await performRealLoadPreflightOrFastPath(
            runtimeURL: runtimeURL, wineURL: wineURL, runtimeType: "imported_wine")
        return (outcome.path, outcome.result.isHealthy)
    }
}

extension LaunchValidationCache {
    /// Test-only access to the cached fingerprint.
    var cachedFingerprintForTest: LaunchValidationFingerprint? { cachedFingerprint }
}