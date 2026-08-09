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
}