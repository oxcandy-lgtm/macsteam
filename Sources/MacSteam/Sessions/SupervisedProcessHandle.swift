// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A Sendable handle to a supervised child process.
/// The underlying `Process` object lives inside `ProcessSupervisor` only.
struct SupervisedProcessHandle: Sendable, Equatable {
    let token: UUID
    let pid: Int32
    let startedAt: Date

    var isValid: Bool { pid > 0 }
}

/// Outcome of waiting for a process to exit.
enum ProcessWaitOutcome: Sendable, Equatable {
    /// The process exited with the given code.
    case exited(Int32)
    /// The timeout was reached before the process exited.
    case timedOut
}
