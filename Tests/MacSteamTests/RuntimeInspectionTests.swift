// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RuntimeInspectionTests {

    @Test func testInspectionStorage() throws {
        let inspection = RuntimeInspection(
            runtimeID: "test-runtime",
            displayName: "Test Runtime",
            version: "1.2.3",
            architecture: "x86_64",
            isUsable: true,
            capabilities: [.windowsProcess, .isolatedPrefix],
            failures: [
                RuntimeFailure(code: .wineserverMissing, message: "wineserver not found")
            ]
        )

        #expect(inspection.runtimeID == "test-runtime")
        #expect(inspection.displayName == "Test Runtime")
        #expect(inspection.version == "1.2.3")
        #expect(inspection.architecture == "x86_64")
        #expect(inspection.isUsable == true)
        #expect(inspection.capabilities.contains(.windowsProcess))
        #expect(inspection.capabilities.contains(.isolatedPrefix))
        #expect(inspection.failures.count == 1)
        #expect(inspection.failures[0].code == .wineserverMissing)
        #expect(inspection.failures[0].message == "wineserver not found")
    }

    @Test func testInspectionDefaultDisplayName() {
        let inspection = RuntimeInspection(
            runtimeID: "my-runtime",
            isUsable: false
        )
        // When displayName is empty, it defaults to runtimeID
        #expect(inspection.displayName == "my-runtime")
    }

    @Test func testInspectionDefaultCapabilities() {
        let inspection = RuntimeInspection(
            runtimeID: "minimal",
            isUsable: true
        )
        #expect(inspection.capabilities.isEmpty)
        #expect(inspection.failures.isEmpty)
    }
}
