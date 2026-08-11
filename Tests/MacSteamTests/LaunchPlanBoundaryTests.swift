// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct LaunchPlanBoundaryTests {

    private let allowedRuntimeRoot = URL(fileURLWithPath: "/tmp/MacSteamTestRuntime")
    private let allowedPrefixRoot = URL(fileURLWithPath: "/tmp/MacSteamTestPrefix/prefix")
    private let allowedEnvKeys: Set<String> = ["WINEDEBUG"]

    private func makeBoundary() -> ExecutionBoundary {
        ExecutionBoundary(
            allowedPrefixRoot: allowedPrefixRoot,
            allowedRuntimeRoots: [allowedRuntimeRoot],
            allowedEnvironmentKeys: allowedEnvKeys
        )
    }

    // MARK: - Executable inside runtime root passes

    @Test func testExecutableInsideRuntimePasses() throws {
        let boundary = makeBoundary()
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: ["WINEPREFIX": allowedPrefixRoot.path],
            boundary: boundary
        )
        // Should not throw
        try boundary.validate(plan: plan)
    }

    // MARK: - Executable outside runtime root fails

    @Test func testExecutableOutsideRuntimeFails() throws {
        let boundary = makeBoundary()
        let outsideExe = URL(fileURLWithPath: "/usr/bin/wine")
        let plan = LaunchPlan(
            runtimeExecutable: outsideExe,
            arguments: [],
            mode: .detached,
            environment: ["WINEPREFIX": allowedPrefixRoot.path],
            boundary: boundary
        )
        #expect(throws: BoundaryViolation.executableOutsideRuntime(outsideExe)) {
            try boundary.validate(plan: plan)
        }
    }

    // MARK: - WINEPREFIX must match allowed root

    @Test func testWINEPREFIXMustMatch() throws {
        let boundary = makeBoundary()
        let wrongPrefix = URL(fileURLWithPath: "/tmp/WrongPrefix")
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: ["WINEPREFIX": wrongPrefix.path],
            boundary: boundary
        )
        #expect(throws: BoundaryViolation.winePrefixNotAllowed(wrongPrefix)) {
            try boundary.validate(plan: plan)
        }
    }

    // MARK: - WINEPREFIX matching allowed parent directory passes

    @Test func testWINEPREFIXInsideAllowedRootPasses() throws {
        let boundary = makeBoundary()
        let nestedPrefix = allowedPrefixRoot.appendingPathComponent("subprefix")
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: ["WINEPREFIX": nestedPrefix.path],
            boundary: boundary
        )
        // Nested path under allowed root is valid
        try boundary.validate(plan: plan)
    }

    // MARK: - Disallowed environment key fails

    @Test func testDisallowedEnvKeyFails() throws {
        let boundary = makeBoundary()
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: [
                "WINEPREFIX": allowedPrefixRoot.path,
                "MY_SECRET_KEY": "s3kr3t"
            ],
            boundary: boundary
        )
        #expect(throws: BoundaryViolation.disallowedEnvironmentKey("MY_SECRET_KEY")) {
            try boundary.validate(plan: plan)
        }
    }

    // MARK: - All default allowed keys don't fail

    @Test func testDefaultAllowedKeysPass() throws {
        let boundary = makeBoundary()
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: [
                "WINEPREFIX": allowedPrefixRoot.path,
                "PATH": "/usr/bin",
                "HOME": "/Users/test",
                "TMPDIR": "/tmp"
            ],
            boundary: boundary
        )
        // Default allowed keys (PATH, HOME, TMPDIR, etc.) should not throw
        try boundary.validate(plan: plan)
    }

    // MARK: - Working directory validation

    @Test func testWorkingDirectoryInsideBoundaryPasses() throws {
        let boundary = ExecutionBoundary(
            allowedPrefixRoot: allowedPrefixRoot,
            allowedRuntimeRoots: [allowedRuntimeRoot],
            allowedEnvironmentKeys: allowedEnvKeys,
            allowedWorkingDirectory: allowedPrefixRoot
        )
        let wd = allowedPrefixRoot.appendingPathComponent("drive_c")
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: ["WINEPREFIX": allowedPrefixRoot.path],
            workingDirectory: wd,
            boundary: boundary
        )
        try boundary.validate(plan: plan)
    }

    @Test func testWorkingDirectoryOutsideBoundaryFails() throws {
        let boundary = ExecutionBoundary(
            allowedPrefixRoot: allowedPrefixRoot,
            allowedRuntimeRoots: [allowedRuntimeRoot],
            allowedEnvironmentKeys: allowedEnvKeys,
            allowedWorkingDirectory: allowedPrefixRoot
        )
        let outsideWD = URL(fileURLWithPath: "/tmp/NotAllowed")
        let plan = LaunchPlan(
            runtimeExecutable: allowedRuntimeRoot.appendingPathComponent("bin/wine"),
            arguments: [],
            mode: .detached,
            environment: ["WINEPREFIX": allowedPrefixRoot.path],
            workingDirectory: outsideWD,
            boundary: boundary
        )
        #expect(throws: BoundaryViolation.workingDirectoryOutsideBoundary(outsideWD)) {
            try boundary.validate(plan: plan)
        }
    }
}
