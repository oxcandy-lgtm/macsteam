// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Describes a CrossOver bottle discovered on the system.
struct BottleDescriptor: Sendable, Equatable {
    let name: String
    let rootURL: URL
    let steamExecutableURL: URL?
}

/// Whether a launched process should be waited on or fire‑and‑forget.
enum LaunchMode: Sendable {
    /// Wait for the process to exit, collecting stdout/stderr.
    case waitForExit
    /// Launch the process and return immediately without waiting.
    case detached
}

/// A ready‑to‑execute launch plan with the runtime binary, arguments,
/// and launch mode.
struct LaunchPlan: Sendable, Equatable {
    let runtimeExecutable: URL
    let arguments: [String]
    let mode: LaunchMode
}
