// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Boolean-only summary of Steam CEF diagnostic output.
///
/// NX Dispatch U1R10 §11 — this classifier reads known sentinel strings
/// from Steam CEF diagnostic logs and returns structured booleans.
/// Raw log content, file paths, PIDs, Steam IDs, and account identifiers
/// are never stored or emitted.
///
/// - Important: Input is processed in-memory only.  The raw log text is
///   discarded after classification.  No log content is written to disk.
struct SteamCEFDiagnosticSummary: Sendable, Equatable {
    let gpuProcessStarted: Bool
    let gpuProcessExitedUnexpectedly: Bool
    let gpuInitializationFailed: Bool
    let rendererStarted: Bool
    let invalidBrowserDimensions: Bool
    let sandboxAlreadyDisabled: Bool

    /// True when no diagnostics could be parsed (empty or unparseable input).
    let empty: Bool
}

/// Classifies CEF diagnostic log lines into a boolean-only summary.
///
/// ## Sentinel patterns (§11)
///
/// | Pattern | Maps to |
/// |---|---|
/// | `GPU process started` | `gpuProcessStarted` |
/// | `GPU process exited unexpectedly` | `gpuProcessExitedUnexpectedly` |
/// | `Exiting GPU process due to errors during initialization` | `gpuInitializationFailed` |
/// | `renderer` | `rendererStarted` |
/// | `Invalid browser dimensions` | `invalidBrowserDimensions` |
/// | `CEF sandbox already disabled` | `sandboxAlreadyDisabled` |
///
enum SteamCEFDiagnosticClassifier: Sendable {
    /// Classify a collection of diagnostic log lines.
    ///
    /// - Parameter logLines: Individual lines of CEF diagnostic output.
    /// - Returns: A summary with booleans set based on sentinel matches.
    static func classify(lines logLines: [String]) -> SteamCEFDiagnosticSummary {
        guard !logLines.isEmpty else {
            return SteamCEFDiagnosticSummary(
                gpuProcessStarted: false,
                gpuProcessExitedUnexpectedly: false,
                gpuInitializationFailed: false,
                rendererStarted: false,
                invalidBrowserDimensions: false,
                sandboxAlreadyDisabled: false,
                empty: true
            )
        }

        let lowerLines = logLines.map { $0.lowercased() }

        return SteamCEFDiagnosticSummary(
            gpuProcessStarted: lowerLines.contains { $0.contains("gpu process started") },
            gpuProcessExitedUnexpectedly: lowerLines.contains { $0.contains("gpu process exited unexpectedly") },
            gpuInitializationFailed: lowerLines.contains { $0.contains("exiting gpu process due to errors during initialization") },
            rendererStarted: lowerLines.contains { $0.contains("renderer") },
            invalidBrowserDimensions: lowerLines.contains { $0.contains("invalid browser dimensions") },
            sandboxAlreadyDisabled: lowerLines.contains { $0.contains("cef sandbox already disabled") },
            empty: false
        )
    }
}
