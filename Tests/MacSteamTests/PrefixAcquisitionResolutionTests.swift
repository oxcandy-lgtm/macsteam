// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import MacSteam

// MARK: - Deterministic prefix acquisition resolution (fail-closed)

@MainActor
struct PrefixAcquisitionResolutionTests {

    // MARK: - Filesystem helpers

    private func makeScratchRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsteam-acq-\(UUID().uuidString)")
    }

    @discardableResult
    private func createValidSteamPrefix(at root: URL, name: String, withSteam: Bool = true) -> URL {
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

    private func makeLayout(root: URL) -> PrefixLayout {
        PrefixLayout(
            root: root,
            driveC: root.appendingPathComponent("drive_c"),
            dosdevices: root.appendingPathComponent("dosdevices"),
            systemReg: root.appendingPathComponent("system.reg"),
            userReg: root.appendingPathComponent("user.reg"),
            windowsSteamCandidates: [
                root.appendingPathComponent("drive_c/Program Files (x86)/Steam"),
                root.appendingPathComponent("drive_c/Program Files/Steam"),
            ]
        )
    }

    // MARK: - Pure resolveAcquisition tests

    @Test("canonical valid → always existingCanonical, adoption not needed")
    func canonicalValid_selectsExistingCanonical() {
        let canonical = makeLayout(root: URL(fileURLWithPath: "/tmp/canonical"))
        let candidate1 = makeLayout(root: URL(fileURLWithPath: "/tmp/test1"))
        let candidate2 = makeLayout(root: URL(fileURLWithPath: "/tmp/test2"))

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: canonical,
            canonicalSteamPresent: true,
            adoptionCandidates: [candidate1, candidate2]
        )

        #expect(resolution.source == .existingCanonical)
        #expect(resolution.layout?.root == canonical.root)
        #expect(!resolution.ambiguous)
        #expect(resolution.log.source == .existingCanonical)
        #expect(resolution.log.canonicalPrefixValid == true)
        #expect(resolution.log.canonicalSteamPresent == true)
        #expect(resolution.log.adoptionCandidateCount == 0)
        #expect(resolution.log.adoptionResult == .notNeeded)
    }

    @Test("canonical valid without Steam → still existingCanonical")
    func canonicalValidNoSteam_stillExistingCanonical() {
        let canonical = makeLayout(root: URL(fileURLWithPath: "/tmp/canonical"))

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: canonical,
            canonicalSteamPresent: false,
            adoptionCandidates: []
        )

        #expect(resolution.source == .existingCanonical)
        #expect(resolution.log.canonicalSteamPresent == false)
        #expect(resolution.log.adoptionResult == .notNeeded)
    }

    @Test("no canonical + exactly 1 candidate → adoptedSteam")
    func noCanonical_uniqueCandidate_adopts() {
        let candidate = makeLayout(root: URL(fileURLWithPath: "/tmp/only"))

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: nil,
            canonicalSteamPresent: false,
            adoptionCandidates: [candidate]
        )

        #expect(resolution.source == .adoptedSteam)
        #expect(resolution.layout?.root == candidate.root)
        #expect(!resolution.ambiguous)
        #expect(resolution.log.adoptionCandidateCount == 1)
        #expect(resolution.log.adoptionResult == .uniqueCandidate)
    }

    @Test("no canonical + 2 candidates → ambiguous, fail-closed")
    func noCanonical_twoCandidates_ambiguousFailClosed() {
        let c1 = makeLayout(root: URL(fileURLWithPath: "/tmp/a"))
        let c2 = makeLayout(root: URL(fileURLWithPath: "/tmp/b"))

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: nil,
            canonicalSteamPresent: false,
            adoptionCandidates: [c1, c2]
        )

        #expect(resolution.ambiguous)
        #expect(resolution.layout == nil)
        #expect(resolution.source == nil)
        #expect(resolution.log.adoptionCandidateCount == 2)
        #expect(resolution.log.adoptionResult == .ambiguous)
    }

    @Test("no canonical + 0 candidates → none, new creation path")
    func noCanonical_zeroCandidates_none() {
        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: nil,
            canonicalSteamPresent: false,
            adoptionCandidates: []
        )

        #expect(!resolution.ambiguous)
        #expect(resolution.layout == nil)
        #expect(resolution.source == nil)
        #expect(resolution.log.adoptionResult == .none)
        #expect(resolution.log.adoptionCandidateCount == 0)
    }

    @Test("candidate order does not affect resolution outcome")
    func orderInvariant() {
        let c1 = makeLayout(root: URL(fileURLWithPath: "/tmp/first"))
        let c2 = makeLayout(root: URL(fileURLWithPath: "/tmp/second"))

        let forward = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: nil, canonicalSteamPresent: false, adoptionCandidates: [c1, c2]
        )
        let reversed = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: nil, canonicalSteamPresent: false, adoptionCandidates: [c2, c1]
        )

        #expect(forward.ambiguous == reversed.ambiguous)
        #expect(forward.source == reversed.source)
        #expect(forward.log.adoptionResult == reversed.log.adoptionResult)
        #expect(forward.log.adoptionCandidateCount == reversed.log.adoptionCandidateCount)
    }

    // MARK: - Filesystem integration: collectAdoptionCandidates

    @Test("collectAdoptionCandidates: canonical + multiple Steam test prefixes → only non-canonical candidates collected")
    func collectCandidates_canonicalPlusTestPrefixes() {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        createValidSteamPrefix(at: scratch, name: "cloverpit")
        createValidSteamPrefix(at: scratch, name: "cloverpit-winecx-freetype-test")
        createValidSteamPrefix(at: scratch, name: "cloverpit-winecx-test")

        let pm = PrefixManager(prefixesRootOverride: scratch)
        let coordinator = UltimateSetupCoordinator(prefixManager: pm)
        let candidates = coordinator.collectAdoptionCandidates()

        #expect(candidates.count == 3)
    }

    @Test("collectAdoptionCandidates: symlink prefix is excluded")
    func collectCandidates_symlinkExcluded() {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let real = createValidSteamPrefix(at: scratch, name: "real-prefix")
        let link = scratch.appendingPathComponent("symlink-prefix")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let pm = PrefixManager(prefixesRootOverride: scratch)
        let coordinator = UltimateSetupCoordinator(prefixManager: pm)
        let candidates = coordinator.collectAdoptionCandidates()

        #expect(candidates.count == 1)
        #expect(candidates[0].root.lastPathComponent == "real-prefix")
    }

    @Test("collectAdoptionCandidates: prefix without steam.exe is excluded")
    func collectCandidates_noSteamExcluded() {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        createValidSteamPrefix(at: scratch, name: "with-steam", withSteam: true)
        createValidSteamPrefix(at: scratch, name: "without-steam", withSteam: false)

        let pm = PrefixManager(prefixesRootOverride: scratch)
        let coordinator = UltimateSetupCoordinator(prefixManager: pm)
        let candidates = coordinator.collectAdoptionCandidates()

        #expect(candidates.count == 1)
        #expect(candidates[0].root.lastPathComponent == "with-steam")
    }

    @Test("collectAdoptionCandidates: invalid signature prefix is excluded")
    func collectCandidates_invalidSignatureExcluded() {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        createValidSteamPrefix(at: scratch, name: "valid-prefix")

        let broken = scratch.appendingPathComponent("broken-prefix")
        try! FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let pm = PrefixManager(prefixesRootOverride: scratch)
        let coordinator = UltimateSetupCoordinator(prefixManager: pm)
        let candidates = coordinator.collectAdoptionCandidates()

        #expect(candidates.count == 1)
        #expect(candidates[0].root.lastPathComponent == "valid-prefix")
    }

    // MARK: - End-to-end: canonical wins over test prefixes

    @Test("canonical valid + multiple Steam test prefixes → canonical selected, not ambiguous")
    func canonicalWithTestPrefixes_selectsCanonical() {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let canonicalURL = createValidSteamPrefix(at: scratch, name: "cloverpit")
        createValidSteamPrefix(at: scratch, name: "cloverpit-winecx-freetype-test")
        createValidSteamPrefix(at: scratch, name: "cloverpit-winecx10-test")

        let canonicalLayout = makeLayout(root: canonicalURL)
        let candidates = [
            makeLayout(root: scratch.appendingPathComponent("cloverpit-winecx-freetype-test")),
            makeLayout(root: scratch.appendingPathComponent("cloverpit-winecx10-test")),
        ]

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: canonicalLayout,
            canonicalSteamPresent: true,
            adoptionCandidates: candidates
        )

        #expect(resolution.source == .existingCanonical)
        #expect(resolution.layout?.root == canonicalURL)
        #expect(!resolution.ambiguous)
        #expect(resolution.log.adoptionResult == .notNeeded)
    }

    @Test("freetype-test listed first does not override production cloverpit")
    func freetypeTestFirst_doesNotOverrideCanonical() {
        let scratch = makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let canonicalURL = createValidSteamPrefix(at: scratch, name: "cloverpit")
        createValidSteamPrefix(at: scratch, name: "cloverpit-winecx-freetype-test")

        let canonicalLayout = makeLayout(root: canonicalURL)
        let freetypeLayout = makeLayout(root: scratch.appendingPathComponent("cloverpit-winecx-freetype-test"))

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: canonicalLayout,
            canonicalSteamPresent: true,
            adoptionCandidates: [freetypeLayout]
        )

        #expect(resolution.source == .existingCanonical)
        #expect(resolution.layout?.root == canonicalURL)
        #expect(resolution.layout?.root.lastPathComponent == "cloverpit")
    }

    // MARK: - Bounded log contract

    @Test("bounded log never contains filesystem paths")
    func boundedLog_noPaths() {
        let canonical = makeLayout(root: URL(fileURLWithPath: "/tmp/test-prefix"))
        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: canonical,
            canonicalSteamPresent: true,
            adoptionCandidates: []
        )

        let log = resolution.log
        #expect(log.source == .existingCanonical)
        #expect(log.canonicalPrefixValid == true)
        #expect(log.canonicalSteamPresent == true)
        #expect(log.adoptionCandidateCount == 0)
        #expect(log.adoptionResult == .notNeeded)

        let mirror = Mirror(reflecting: log)
        for child in mirror.children {
            if let str = child.value as? String {
                #expect(!str.contains("/"), "log field must not contain path separators")
            }
        }
    }

    @Test("ambiguous log records candidate count without names")
    func ambiguousLog_countOnly() {
        let c1 = makeLayout(root: URL(fileURLWithPath: "/tmp/x"))
        let c2 = makeLayout(root: URL(fileURLWithPath: "/tmp/y"))
        let c3 = makeLayout(root: URL(fileURLWithPath: "/tmp/z"))

        let resolution = UltimateSetupCoordinator.resolveAcquisition(
            validatedLayout: nil,
            canonicalSteamPresent: false,
            adoptionCandidates: [c1, c2, c3]
        )

        #expect(resolution.log.adoptionCandidateCount == 3)
        #expect(resolution.log.adoptionResult == .ambiguous)
        #expect(resolution.log.source == nil)
    }
}
