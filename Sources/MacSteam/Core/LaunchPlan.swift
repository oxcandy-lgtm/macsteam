// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether a launched process should be waited on or fire‑and‑forget.
enum LaunchMode: Sendable {
    /// Wait for the process to exit, collecting stdout/stderr.
    case waitForExit
    /// Launch the process and return immediately without waiting.
    case detached
}

/// A ready‑to‑execute launch plan with the runtime binary, arguments,
/// environment, working directory, and safety boundary.
struct LaunchPlan: Sendable, Equatable {
    let runtimeExecutable: URL
    let arguments: [String]
    let mode: LaunchMode
    let environment: [String: String]
    let workingDirectory: URL?
    let boundary: ExecutionBoundary?

    init(
        runtimeExecutable: URL,
        arguments: [String],
        mode: LaunchMode,
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        boundary: ExecutionBoundary? = nil
    ) {
        self.runtimeExecutable = runtimeExecutable
        self.arguments = arguments
        self.mode = mode
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.boundary = boundary
    }
}
