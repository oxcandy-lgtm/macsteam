// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct AppInstanceGuardFingerprintTests {
    @Test("empty executable payload has a deterministic bounded fingerprint")
    func emptyPayloadFingerprint() {
        let fingerprint = AppInstanceGuard.executableFingerprint(for: Data())

        #expect(fingerprint == "JSMihOSc8sswX2j7")
        #expect(fingerprint.count == 16)
    }

    @Test("known payload has a deterministic independent known vector")
    func knownPayloadFingerprint() {
        let payload = Data("MacsTeam fingerprint known vector".utf8)
        let expected = "Dm0H4OzXTTEbEU2f"

        let first = AppInstanceGuard.executableFingerprint(for: payload)
        let second = AppInstanceGuard.executableFingerprint(for: payload)

        #expect(first == expected)
        #expect(second == expected)
        #expect(first == second)
        #expect(first.count == 16)
    }

    @Test("large executable payload remains deterministic and bounded")
    func largePayloadFingerprint() {
        let payload = Data(repeating: UInt8(0xA5), count: 1_048_576)

        let first = AppInstanceGuard.executableFingerprint(for: payload)
        let second = AppInstanceGuard.executableFingerprint(for: payload)

        #expect(!first.isEmpty)
        #expect(first.count == 16)
        #expect(first == second)
    }

    @Test("actual test executable bytes produce a fingerprint")
    func actualExecutableFingerprint() throws {
        guard let executableURL = Bundle.main.executableURL else {
            Issue.record("Test executable URL was unavailable")
            return
        }
        let executableData = try Data(contentsOf: executableURL)
        #expect(!executableData.isEmpty)

        let fingerprint = AppInstanceGuard.executableFingerprint(for: executableData)
        #expect(!fingerprint.isEmpty)
        #expect(fingerprint.count == 16)
    }

    @Test("fingerprint implementation does not mutate an Array object representation")
    func unsafeArrayMutationRegressionGuard() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacSteam/App/AppInstanceGuard.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let forbiddenFragments = [
            "withUnsafe" + "MutableBytes(of: &hash)",
            "bindMemory(to: UInt64.self)",
            "unsafe" + "BitCast"
        ]

        for fragment in forbiddenFragments {
            #expect(!source.contains(fragment), "Forbidden fingerprint memory operation: \(fragment)")
        }
    }

    @Test("repeated fingerprint invocation is stable")
    func repeatedInvocation() {
        let payload = Data("repeated invocation regression".utf8)
        let fingerprints = (0..<100).map { _ in
            AppInstanceGuard.executableFingerprint(for: payload)
        }

        #expect(Set(fingerprints).count == 1)
        #expect(fingerprints.first?.count == 16)
    }
}
