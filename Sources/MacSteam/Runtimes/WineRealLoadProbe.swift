// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of a real-load Wine executability probe.
struct WineRealLoadResult: Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        /// Wine actually executed a Windows command and reported a version.
        case healthy
        /// Wine could not load a required dynamic library (FreeType catastrophe).
        case dependencyMissing
        /// The process failed to launch or exited non-zero without a known marker.
        case launchFailed
        /// The probe exceeded its deadline — treated as failure (fail-closed).
        case timedOut
    }

    let status: Status
    let detail: String
    let windowsVersion: String?
    let exitCode: Int32?

    init(status: Status, detail: String, windowsVersion: String? = nil, exitCode: Int32? = nil) {
        self.status = status
        self.detail = detail
        self.windowsVersion = windowsVersion
        self.exitCode = exitCode
    }

    var isHealthy: Bool { status == .healthy }
}

/// Runs a real-load Wine executability probe against a runtime.
///
/// The probe executes `wine cmd /c ver` inside a freshly-created null-prefix
/// using the runtime's dependency layout (DYLD_LIBRARY_PATH / FONTCONFIG_PATH).
/// It exists to catch the "FreeType catastrophe" — Wine builds that cannot
/// resolve their bundled dynamic libraries — BEFORE any real Steam launch.
///
/// Failure modes are differentiated so callers can fail closed:
///   - stderr containing `Wine cannot find the FreeType font library` →
///     `.dependencyMissing` (even when exit code is 0, which Wine does).
///   - a real timeout → `.timedOut`.
///   - non-zero exit / missing executable → `.launchFailed`.
struct WineRealLoadProbe: Sendable {

    /// Marker emitted by Wine when the FreeType font library cannot be loaded.
    static let freeTypeCatastropheMarker = "cannot find the FreeType font library"

    /// Lowercased marker — comparison is case-insensitive.
    private static let freeTypeCatastropheMarkerLowercased = freeTypeCatastropheMarker.lowercased()

    /// Maximum seconds a probe may run before being treated as a timeout.
    static let defaultTimeout: TimeInterval = 60

    /// Classify raw probe output into a `Status` (pure — deterministic).
    ///
    /// - Parameters:
    ///   - stdout: Captured stdout.
    ///   - stderr: Captured stderr.
    ///   - exitCode: Process exit code (`nil` when the process never exited).
    /// - Returns: The classified status.
    static func classify(stdout: String, stderr: String, exitCode: Int32?) -> WineRealLoadResult.Status {
        let combined = "\(stdout)\n\(stderr)"
        if combined.lowercased().contains(freeTypeCatastropheMarkerLowercased) {
            return .dependencyMissing
        }
        if let code = exitCode, code != 0 {
            return .launchFailed
        }
        // Healthy Wine prints "Microsoft Windows <version>" from `cmd /c ver`.
        if stdout.contains("Microsoft Windows") {
            return .healthy
        }
        if exitCode == nil {
            return .timedOut
        }
        return .launchFailed
    }

    /// Extract the Windows version string from `cmd /c ver` stdout.
    static func windowsVersion(from stdout: String) -> String? {
        let needle = "Microsoft Windows"
        guard let range = stdout.range(of: needle) else { return nil }
        let tail = String(stdout[range.upperBound...])
        let tokens = tail.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard let version = tokens.first else { return nil }
        return needle + " " + version
    }

    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Run the real-load probe against the given runtime.
    ///
    /// - Parameters:
    ///   - runtimeURL: The runtime root URL (used for the dependency layout).
    ///   - wineURL: The resolved `wine` executable URL.
    ///   - scratchPrefixRoot: Directory under which a fresh null-prefix is created.
    ///   - timeout: Probe deadline; defaults to `defaultTimeout`.
    /// - Returns: A `WineRealLoadResult` describing the probe outcome.
    func probe(
        runtimeURL: URL,
        wineURL: URL,
        scratchPrefixRoot: URL,
        timeout: TimeInterval = WineRealLoadProbe.defaultTimeout
    ) async -> WineRealLoadResult {
        guard let depLayout = RuntimeDependencyLayout(runtimePath: runtimeURL.path) else {
            return WineRealLoadResult(
                status: .launchFailed,
                detail: "RuntimeDependencyLayout unavailable for \(runtimeURL.path)"
            )
        }

        let scratch = scratchPrefixRoot
            .appendingPathComponent("__preflight-\(UUID().uuidString.lowercased())", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return WineRealLoadResult(
                status: .launchFailed,
                detail: "Failed to create scratch prefix: \(error.localizedDescription)"
            )
        }
        defer { try? fm.removeItem(at: scratch) }

        // Build the dependency-aware environment as production does, falling
        // back to a deps-aware basic env when the canonical-prefix boundary
        // rejects the scratch prefix (scratch lives outside Prefixes/).
        var environment: [String: String]
        if let builder = try? WineLaunchEnvironmentBuilder(
            winePrefix: scratch,
            dependencyLayout: depLayout
        ) {
            environment = builder.build()
        } else {
            environment = SafeProcessEnvironment.base
            let fm = FileManager.default
            let libDir = depLayout.libDirectory()
            if fm.fileExists(atPath: libDir.path) {
                environment["DYLD_LIBRARY_PATH"] = libDir.path
            }
            let fcDir = depLayout.fontconfigDirectory()
            if fm.fileExists(atPath: fcDir.path) {
                environment["FONTCONFIG_PATH"] = fcDir.path
            }
            environment["WINEPREFIX"] = scratch.path
        }

        do {
            let result = try await processRunner.run(
                executable: wineURL,
                arguments: ["cmd", "/c", "ver"],
                environment: environment,
                workingDirectory: scratch,
                timeout: timeout,
                mode: .waitForExit
            )

            let status = Self.classify(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode
            )

            return WineRealLoadResult(
                status: status,
                detail: status == .healthy ? "real-load OK" : Self.detailFor(status, stderr: result.stderr),
                windowsVersion: Self.windowsVersion(from: result.stdout),
                exitCode: result.exitCode
            )
        } catch let error as ProcessRunner.RunnerError {
            switch error {
            case .timeoutReached:
                return WineRealLoadResult(
                    status: .timedOut,
                    detail: "Real-load probe timed out after \(Int(timeout))s",
                    exitCode: nil
                )
            case .executableNotFound, .executableNotRegularFile:
                return WineRealLoadResult(
                    status: .launchFailed,
                    detail: "wine executable unavailable: \(error.localizedDescription)"
                )
            default:
                return WineRealLoadResult(
                    status: .launchFailed,
                    detail: "Real-load probe failed: \(error.localizedDescription)"
                )
            }
        } catch {
            return WineRealLoadResult(
                status: .launchFailed,
                detail: "Real-load probe failed: \(error.localizedDescription)"
            )
        }
    }

    private static func detailFor(_ status: WineRealLoadResult.Status, stderr: String) -> String {
        switch status {
        case .dependencyMissing:
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Wine dependency load failure (FreeType catastrophe): \(trimmed)"
        case .launchFailed:
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Wine real-load failed (non-zero exit)" : "Wine real-load failed: \(trimmed)"
        case .healthy, .timedOut:
            return status.rawValue
        }
    }
}
