// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
import Darwin
@testable import MacSteam

// MARK: - Store test helpers

private func makeGatedAcceptedReceipt(visibility: Int = 30) -> LocalAcceptanceReceipt {
    let evidence = LocalAcceptanceReceipt.Evidence(
        importedWineSelected: true,
        runtimeRealLoadHealthy: true,
        canonicalPrefixBound: true,
        steamInstallVerified: true,
        cloverpitInstallReady: true,
        supervisedGameSessionStarted: true,
        ownershipCensusProven: true,
        targetWindowVisible: true,
        visibilityStableSeconds: visibility,
        mainMenuConfirmedByOperator: true,
        inputResponseConfirmedByOperator: true,
        cleanupComplete: true
    )
    return LocalAcceptanceReceipt(state: .accepted, blocker: "none", evidence: evidence)
}

private func makeTempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lavi-receipt-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func store(at root: URL) -> LocalAcceptanceReceiptStore {
    LocalAcceptanceReceiptStore(applicationSupportRoot: root)
}

private func receiptPath(in root: URL) -> URL {
    root.appendingPathComponent("Acceptance").appendingPathComponent("cloverpit.json")
}

// MARK: - Tests

@Suite("LocalAcceptanceReceiptStore")
struct LocalAcceptanceReceiptStoreTests {
    // MARK: Save gate

    @Test func saveRejectsBlockedReceipt() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        let blocked = LocalAcceptanceReceipt(state: .blocked, blocker: "did_stuff",
                                             evidence: .empty)
        #expect(s.saveAccepted(blocked) == .failed(.notAccepted))
    }

    @Test func saveRejectsInProgressReceipt() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = LocalAcceptanceReceipt(state: .inProgress, blocker: "none", evidence: .empty)
        #expect(store(at: root).saveAccepted(receipt) == .failed(.notAccepted))
    }

    @Test func saveRejectsInvalidatedReceipt() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = LocalAcceptanceReceipt(state: .invalidated, blocker: "none", evidence: .empty)
        #expect(store(at: root).saveAccepted(receipt) == .failed(.notAccepted))
    }

    @Test func saveRejectsBlockerNotNone() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = LocalAcceptanceReceipt(state: .accepted, blocker: "a_blocker",
                                             evidence: makeGatedAcceptedReceipt().evidence)
        #expect(store(at: root).saveAccepted(receipt) == .failed(.blockerNotNone))
    }

    @Test func saveRejectsIncompleteEvidenceEachMissingProof() {
        let faults: [(keyPath: WritableKeyPath<LocalAcceptanceReceipt.Evidence, Bool>, flag: String)] = [
            (\.importedWineSelected, "imported_wine_selected"),
            (\.runtimeRealLoadHealthy, "runtime_real_load_healthy"),
            (\.canonicalPrefixBound, "canonical_prefix_bound"),
            (\.steamInstallVerified, "steam_install_verified"),
            (\.cloverpitInstallReady, "cloverpit_install_ready"),
            (\.supervisedGameSessionStarted, "supervised_game_session_started"),
            (\.ownershipCensusProven, "ownership_census_proven"),
            (\.targetWindowVisible, "target_window_visible"),
            (\.mainMenuConfirmedByOperator, "main_menu_confirmed_by_operator"),
            (\.inputResponseConfirmedByOperator, "input_response_confirmed_by_operator"),
            (\.cleanupComplete, "cleanup_complete"),
        ]
        for entry in faults {
            let root = makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var receipt = makeGatedAcceptedReceipt()
            receipt.evidence[keyPath: entry.0] = false
            let result = store(at: root).saveAccepted(receipt)
            #expect(result == .failed(.evidenceIncomplete), "\(entry.1) missing")
        }
    }

    @Test func saveRejectsVisibilityBelowMinimum() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = makeGatedAcceptedReceipt(visibility: 29)
        #expect(store(at: root).saveAccepted(receipt) == .failed(.visibilityBelowMinimum))
    }

    @Test func saveRejectsTargetMismatch() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var receipt = makeGatedAcceptedReceipt()
        receipt.target = LocalAcceptanceReceipt.Target(recipeID: "other", steamAppID: "000")
        #expect(store(at: root).saveAccepted(receipt) == .failed(.targetMismatch))
    }

    @Test func saveRejectsSecurityAnyFlagSet() {
        var receipt = makeGatedAcceptedReceipt()
        let cases: [WritableKeyPath<LocalAcceptanceReceipt.Security, Bool>] = [
            \.credentialsAccessed,
            \.rawPIDEmitted,
            \.rawPathEmitted,
            \.rawSessionIDEmitted,
            \.rawWindowIdentityEmitted,
        ]
        for kp in cases {
            let root = makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var mutated = makeGatedAcceptedReceipt()
            mutated.security[keyPath: kp] = true
            #expect(store(at: root).saveAccepted(mutated) == .failed(.securityFlagSet))
        }
    }

    // MARK: Save/load round trip & canonical bytes

    @Test func saveWritesExactCanonicalBytesAndLoads() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        let receipt = makeGatedAcceptedReceipt()
        #expect(s.saveAccepted(receipt) == .saved)
        #expect(s.loadAccepted() == .loaded(receipt))
        let diskBytes = try? Data(contentsOf: receiptPath(in: root))
        #expect(diskBytes == receipt.deterministicJSON)
    }

    @Test func loadReturnsNotFoundWhenAbsent() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store(at: root).loadAccepted() == .notFound)
    }

    @Test func loadRejectsNonCanonicalBytes() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        let receipt = makeGatedAcceptedReceipt()
        _ = s.saveAccepted(receipt)
        // Perturb a byte while keeping it canonical-decodable (add whitespace the
        // deterministic re-encode would remove).
        let path = receiptPath(in: root)
        var text = try! String(contentsOf: path, encoding: .utf8)
        text = text.replacingOccurrences(of: #""schema_version":1"#, with: #""schema_version": 1"#)
        try! text.write(to: path, atomically: true, encoding: .utf8)
        #expect(s.loadAccepted() == .failed(.nonCanonicalBytes))
    }

    @Test func loadRejectsMalformedJSON() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Acceptance"),
                                                 withIntermediateDirectories: true)
        try! Data("{ not valid json ".utf8).write(to: receiptPath(in: root))
        #expect(store(at: root).loadAccepted() == .failed(.malformedJSON))
    }

    @Test func loadRejectsOversizedFile() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Acceptance"),
                                                 withIntermediateDirectories: true)
        let big = Data(repeating: 0x61, count: LocalAcceptanceReceiptStore.maxReceiptBytes + 1)
        try! big.write(to: receiptPath(in: root))
        #expect(store(at: root).loadAccepted() == .failed(.oversized))
    }

    // MARK: Filesystem safety

    @Test func saveCreatesPrivateDirAndPrivateFile() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        _ = s.saveAccepted(makeGatedAcceptedReceipt())
        let parent = root.appendingPathComponent("Acceptance")
        let attrs = try! FileManager.default.attributesOfItem(atPath: parent.path)
        let fileAttrs = try! FileManager.default.attributesOfItem(atPath: receiptPath(in: root).path)
        let parentPerms = (attrs[.posixPermissions] as? Int ?? 0) & 0o777
        let filePerms = (fileAttrs[.posixPermissions] as? Int ?? 0) & 0o777
        #expect(parentPerms == LocalAcceptanceReceiptStore.parentDirectoryPermissions)
        #expect(filePerms == LocalAcceptanceReceiptStore.receiptFilePermissions)
    }

    @Test func saveIsAtomicNoResidualTempFiles() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        #expect(s.saveAccepted(makeGatedAcceptedReceipt()) == .saved)
        let residual = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Acceptance").path))
            ?? []
        #expect(residual == ["cloverpit.json"])
    }

    @Test func saveRejectsSymlinkParent() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Make a fake neighbour target.
        let target = root.appendingPathComponent("elsewhere")
        try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createSymbolicLink(
            at: parent,
            withDestinationURL: target
        )
        #expect(store(at: root).saveAccepted(makeGatedAcceptedReceipt()) == .failed(.symlinkParentEscapeRejected))
    }

    @Test func saveRejectsSymlinkDestination() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let realFile = parent.appendingPathComponent("real.json")
        try! "x".write(to: realFile, atomically: true, encoding: .utf8)
        try! FileManager.default.createSymbolicLink(at: receiptPath(in: root), withDestinationURL: realFile)
        #expect(store(at: root).saveAccepted(makeGatedAcceptedReceipt()) == .failed(.symlinkDestinationRejected))
    }

    @Test func loadRejectsNonRegularFile() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: receiptPath(in: root), withIntermediateDirectories: true)
        #expect(store(at: root).loadAccepted() == .failed(.nonRegularFile))
    }

    @Test func loadRejectsSymlinkDestination() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let real = parent.appendingPathComponent("real.json")
        try! "#{}#".data(using: .utf8)!.write(to: real)
        try! FileManager.default.createSymbolicLink(at: receiptPath(in: root), withDestinationURL: real)
        let result = store(at: root).loadAccepted()
        // A symlink destination is rejected exactly (ELOOP), never read.
        #expect(result == .failed(.symlinkDestinationRejected))
    }

    // MARK: U1R18-R12-FIX1 durable receipt fail-closed repair

    @Test func replacementSaveSucceeds() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        let a = makeGatedAcceptedReceipt()
        let b = makeGatedAcceptedReceipt(visibility: 31)
        #expect(s.saveAccepted(a) == .saved)
        #expect(s.saveAccepted(b) == .saved)
        // The newest canonical receipt replaces the old one.
        #expect(s.loadAccepted() == .loaded(b))
        let diskBytes = try? Data(contentsOf: receiptPath(in: root))
        #expect(diskBytes == b.deterministicJSON)
    }

    @Test func replacementFailurePreservesExistingReceiptAndCleansTempOnly() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        let a = makeGatedAcceptedReceipt()
        #expect(s.saveAccepted(a) == .saved)
        let original = try! Data(contentsOf: receiptPath(in: root))
        // Freeze the destination: an immutable receipt cannot be atomically
        // replaced, forcing the write path to fail after the temp is staged.
        let destPath = receiptPath(in: root).path
        #expect(destPath.withCString { chflags($0, UInt32(UF_IMMUTABLE)) } == 0)
        defer { _ = destPath.withCString { chflags($0, 0) } }
        let b = makeGatedAcceptedReceipt(visibility: 31)
        #expect(s.saveAccepted(b) == .failed(.ioFailure))
        // The last-known-good receipt survives byte-identically.
        #expect(try! Data(contentsOf: receiptPath(in: root)) == original)
        // Only the temp was cleaned up; no residual temp remains.
        let parent = root.appendingPathComponent("Acceptance")
        let residual = try! FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(residual == ["cloverpit.json"])
    }

    @Test func permissionDeniedIsIOFailureNotNotFound() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try! "#{}#".data(using: .utf8)!.write(to: receiptPath(in: root))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000],
                                               ofItemAtPath: receiptPath(in: root).path)
        // The file exists but is unreadable: that is an I/O failure, never
        // `.notFound`.
        #expect(store(at: root).loadAccepted() == .failed(.ioFailure))
    }

    @Test(.timeLimit(.minutes(1)))
    func fifoRejectedAsNonRegularWithoutBlocking() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fifoPath = receiptPath(in: root).path
        #expect(fifoPath.withCString { mkfifo($0, 0o600) } == 0)
        // The load must reject the FIFO as a non-regular file and must not
        // block waiting on a writer (O_NONBLOCK open + fstat proof before read).
        // The timeLimit trait fails the test if the load hangs on the FIFO.
        #expect(store(at: root).loadAccepted() == .failed(.nonRegularFile))
    }

    @Test func symlinkLoadRejectedExact() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let real = parent.appendingPathComponent("real.json")
        try! "{}".data(using: .utf8)!.write(to: real)
        try! FileManager.default.createSymbolicLink(at: receiptPath(in: root), withDestinationURL: real)
        // A symlink destination is rejected exactly, before any read.
        #expect(store(at: root).loadAccepted() == .failed(.symlinkDestinationRejected))
    }

    @Test func oversizedRegularFileRejected() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Acceptance")
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let big = Data(repeating: 0x61, count: LocalAcceptanceReceiptStore.maxReceiptBytes + 1)
        try! big.write(to: receiptPath(in: root))
        #expect(store(at: root).loadAccepted() == .failed(.oversized))
    }

    @Test func loadedCanonicalReceiptIsExact() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = store(at: root)
        let receipt = makeGatedAcceptedReceipt()
        _ = s.saveAccepted(receipt)
        // A canonical accepted file loads to the exact receipt.
        #expect(s.loadAccepted() == .loaded(receipt))
    }
}