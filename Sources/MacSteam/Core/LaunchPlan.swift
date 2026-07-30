// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether a launched process should be waited on or supervised as a long-lived session.
enum LaunchMode: Sendable {
    /// Short-lived process; the owner awaits termination then discards.
    case waitForExit
    /// Long-lived session handled by GameSessionSupervisor.
    case supervisedSession
    /// Legacy fire-and-forget — do not use for Ultimate/Installer sessions.
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
