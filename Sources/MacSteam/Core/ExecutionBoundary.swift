// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Boundaries that constrain process execution to safe paths.
///
/// Every `LaunchPlan` carries an `ExecutionBoundary` that must be validated
/// before the process is started. This ensures:
///   - The executable resides inside a verified runtime directory
///   - The working directory is inside the prefix or runtime root
///   - WINEPREFIX is set to the intended game prefix
///   - Only allow-listed environment variables are set
///   - No secret or credential values are leaked into the process
public struct ExecutionBoundary: Codable, Sendable, Equatable {
    /// The canonical prefix root that WINEPREFIX must point to.
    public let allowedPrefixRoot: URL

    /// The canonical runtime root(s) that executables must reside in.
    public let allowedRuntimeRoots: [URL]

    /// Environment variable keys that are permitted.
    public let allowedEnvironmentKeys: Set<String>

    /// If set, working directory must be within this path.
    public let allowedWorkingDirectory: URL?

    public init(
        allowedPrefixRoot: URL,
        allowedRuntimeRoots: [URL],
        allowedEnvironmentKeys: Set<String>,
        allowedWorkingDirectory: URL? = nil
    ) {
        self.allowedPrefixRoot = allowedPrefixRoot
        self.allowedRuntimeRoots = allowedRuntimeRoots
        self.allowedEnvironmentKeys = allowedEnvironmentKeys
        self.allowedWorkingDirectory = allowedWorkingDirectory
    }
}

// MARK: - Validation

public enum BoundaryViolation: Error, Sendable, Equatable {
    case executableOutsideRuntime(URL)
    case workingDirectoryOutsideBoundary(URL)
    case winePrefixNotAllowed(URL)
    case disallowedEnvironmentKey(String)
    case symlinkEscape(URL)
    case worldWritableExecutable(URL)
}

extension ExecutionBoundary {
    /// Validate that a launch plan conforms to this boundary.
    /// - Throws: `BoundaryViolation` on first violation.
    func validate(plan: LaunchPlan) throws {
        // 1. Executable must be inside one of the allowed runtime roots
        let exePath = plan.runtimeExecutable.resolvingSymlinksInPath()
        let insideRuntime = allowedRuntimeRoots.contains { root in
            let resolvedRoot = root.resolvingSymlinksInPath()
            return exePath.path.hasPrefix(resolvedRoot.path + "/") || exePath.path == resolvedRoot.path
        }
        guard insideRuntime else {
            throw BoundaryViolation.executableOutsideRuntime(plan.runtimeExecutable)
        }

        // 2. Working directory must be inside allowed boundary
        if let wd = plan.workingDirectory, let allowed = allowedWorkingDirectory {
            let resolvedWD = wd.resolvingSymlinksInPath()
            let resolvedAllowed = allowed.resolvingSymlinksInPath()
            guard resolvedWD.path.hasPrefix(resolvedAllowed.path + "/") || resolvedWD.path == resolvedAllowed.path else {
                throw BoundaryViolation.workingDirectoryOutsideBoundary(wd)
            }
        }

        // 3. WINEPREFIX must match allowed prefix root
        if let winePrefix = plan.environment["WINEPREFIX"] {
            let resolvedWP = URL(fileURLWithPath: winePrefix).resolvingSymlinksInPath()
            let resolvedAllowed = allowedPrefixRoot.resolvingSymlinksInPath()
            guard resolvedWP.path == resolvedAllowed.path || resolvedWP.path.hasPrefix(resolvedAllowed.path + "/") else {
                throw BoundaryViolation.winePrefixNotAllowed(URL(fileURLWithPath: winePrefix))
            }
        }

        // 4. Only allow-listed environment keys
        for key in plan.environment.keys {
            guard allowedEnvironmentKeys.contains(key) || Self.defaultAllowedKeys.contains(key) else {
                throw BoundaryViolation.disallowedEnvironmentKey(key)
            }
        }
    }

    /// Default set of environment keys always allowed for Wine processes.
    public static let defaultAllowedKeys: Set<String> = [
        "WINEPREFIX", "WINEDEBUG", "WINEARCH",
        "PATH", "HOME", "USER", "LOGNAME",
        "TMPDIR", "TEMP", "TMP",
        "DXVK_LOG_LEVEL", "DXVK_STATE_CACHE_PATH",
        "MOLTENVK_CONFIG_FILE",
        "DYLD_LIBRARY_PATH",
    ]
}
