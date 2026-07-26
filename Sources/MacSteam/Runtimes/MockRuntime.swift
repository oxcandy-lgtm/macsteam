// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A fully mocked runtime for testing UI and state transitions without
/// a real Wine or CrossOver installation.
///
/// Configure behaviour by setting properties before calling methods.
final class MockRuntime: @unchecked Sendable {
    static let runtimeID = "mock"

    var simulatedInspection: RuntimeInspection
    var shouldThrowOnValidate = false
    var simulatedLaunchPlan: LaunchPlan?

    // Call tracking for tests
    var didCallInspect = false
    var didCallValidate = false
    var didCallLaunchPlan = false

    init(inspection: RuntimeInspection? = nil) {
        self.simulatedInspection = inspection ?? RuntimeInspection(
            runtimeID: "mock",
            displayName: "Mock Runtime",
            version: "1.0.0",
            isUsable: true
        )
    }

    init?(url: URL) {
        self.simulatedInspection = RuntimeInspection(runtimeID: "mock", isUsable: true)
    }

    static func detectSystem() -> Bool { true }
}

// MARK: - CompatibilityRuntime conformance

extension MockRuntime: CompatibilityRuntime {
    func inspect() -> RuntimeInspection {
        didCallInspect = true
        return simulatedInspection
    }

    func validate() throws {
        didCallValidate = true
        if shouldThrowOnValidate {
            throw RuntimeFailure(code: .bundleNotValid, message: "Mock validation error")
        }
    }

    func launchPlan(for recipe: GameRecipe) -> LaunchPlan? {
        didCallLaunchPlan = true
        return simulatedLaunchPlan ?? LaunchPlan(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: recipe.launch.storeArguments,
            mode: .detached
        )
    }
}
