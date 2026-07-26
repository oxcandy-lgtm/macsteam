// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Represents the high-level state of the launcher.
///
/// Used by `GameManager` to drive UI state transitions.
enum LauncherState: Equatable, Sendable {
    /// Initial state – performing detection.
    case inspecting
    /// No compatible runtime was found.
    case runtimeMissing
    /// A runtime was found but is not usable.
    case runtimeInvalid(RuntimeFailure)
    /// No Windows Steam installation was detected inside any runtime.
    case storeMissing
    /// Steam was found but the game is not installed.
    case gameNotInstalled
    /// Everything is ready for launch.
    case ready
    /// A launch is in progress.
    case launching
    /// An unrecoverable error occurred.
    case failed(LauncherFailure)
}

/// Errors that can occur during game launch or management.
enum LauncherFailure: Error, Equatable, Sendable {
    case processExecutableInvalid
    case processStartFailed(underlying: String)
    case processExitedWithError(code: Int32)
    case processTimedOut
    case processCancelled
}

/// Stable, machine‑readable error codes.
enum ErrorCode: String, Equatable, Sendable {
    case runtimeNotFound = "RUNTIME_NOT_FOUND"
    case runtimeInvalid = "RUNTIME_INVALID"
    case windowsSteamNotFound = "WINDOWS_STEAM_NOT_FOUND"
    case nativeMacSteamOnly = "NATIVE_MAC_STEAM_ONLY"
    case gameManifestNotFound = "GAME_MANIFEST_NOT_FOUND"
    case gameFilesNotFound = "GAME_FILES_NOT_FOUND"
    case recipeInvalid = "RECIPE_INVALID"
    case processExecutableInvalid = "PROCESS_EXECUTABLE_INVALID"
    case processStartFailed = "PROCESS_START_FAILED"
    case processExitedWithError = "PROCESS_EXITED_WITH_ERROR"
    case processTimedOut = "PROCESS_TIMED_OUT"
    case processCancelled = "PROCESS_CANCELLED"
}
