// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Protocol that each runtime adapter must implement to provide
/// wineserver control for its own Wine distribution.
protocol WineRuntimeControl: Sendable {
    /// The URL to the `wineserver` executable for this runtime.
    var wineserverExecutable: URL { get }

    /// Environment variables needed to control the given prefix.
    func controlEnvironment(for prefix: URL) throws -> [String: String]
}

/// Errors from WineServerController operations.
enum WineServerError: Error, Sendable, LocalizedError {
    case wineserverNotFound(URL)
    case wineserverTerminated(Int32)
    case prefixNotFound(URL)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .wineserverNotFound(let url): return "wineserver not found at \(url.path)"
        case .wineserverTerminated(let code): return "wineserver exited with code \(code)"
        case .prefixNotFound(let url): return "Prefix not found at \(url.path)"
        case .timeout(let msg): return "Timeout waiting for wineserver: \(msg)"
        }
    }
}

/// Controls the Wine server lifecycle for a single prefix.
///
/// **U1R7:** All operations are scoped to exactly one prefix.
/// Global `pkill`/`killall`/`wineserver` calls are forbidden.
/// `isRunning` is determined by a short-timeout `wineserver -w` probe,
/// not by checking the lock file.  Timeout uses `ProcessWaitOutcome`.
actor WineServerController {

    /// Send a graceful shutdown request (`wineserver -k`) and wait for
    /// the server to exit.  Returns `true` on confirmed shutdown.
    ///
    /// - Parameters:
    ///   - runtime: The runtime adapter providing wineserver.
    ///   - prefix: The prefix URL to target (WINEPREFIX).
    ///   - waitSeconds: Max seconds to wait for wineserver to exit.
    /// - Returns: `true` if wineserver exited.
    /// - Throws: `WineServerError` on failure or timeout.
    @discardableResult
    func shutdownPrefix(
        runtime: WineRuntimeControl,
        prefix: URL,
        waitSeconds: Int = 10
    ) async throws -> Bool {
        try verifyPrefix(prefix)

        let env = try runtime.controlEnvironment(for: prefix)

        // Step 1: wineserver -k (request shutdown)
        switch try await runWineserver(
            executable: runtime.wineserverExecutable,
            arguments: ["-k"],
            environment: env,
            timeout: .seconds(10)
        ) {
        case .exited(let code):
            guard code == 0 else {
                throw WineServerError.wineserverTerminated(code)
            }
        case .timedOut:
            throw WineServerError.timeout("wineserver -k did not complete within 10s")
        }

        // Step 2: wineserver -w (wait for exit)
        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        while Date() < deadline {
            switch try await runWineserver(
                executable: runtime.wineserverExecutable,
                arguments: ["-w"],
                environment: env,
                timeout: .milliseconds(300)
            ) {
            case .exited:
                return true
            case .timedOut:
                continue // server still running, poll again
            }
        }

        throw WineServerError.timeout("wineserver did not stop within \(waitSeconds)s")
    }

    /// Send a `wineserver -k` request (graceful shutdown signal).
    /// No follow-up wait.  Used for user-requested Force Stop.
    func requestServerKill(
        runtime: WineRuntimeControl,
        prefix: URL
    ) async throws {
        try verifyPrefix(prefix)
        let env = try runtime.controlEnvironment(for: prefix)

        switch try await runWineserver(
            executable: runtime.wineserverExecutable,
            arguments: ["-k"],
            environment: env,
            timeout: .seconds(30)
        ) {
        case .exited(let code):
            guard code == 0 else {
                throw WineServerError.wineserverTerminated(code)
            }
        case .timedOut:
            // Best-effort: the kill request was sent even if wineserver
            // didn't respond. The server may exit asynchronously.
            return
        }
    }

    /// Check whether a wineserver is running for the given prefix.
    /// Uses a short-timeout `-w` probe (300ms).
    func isRunning(prefix: URL, runtime: WineRuntimeControl) async throws -> Bool {
        try verifyPrefix(prefix)
        let env = try runtime.controlEnvironment(for: prefix)

        switch try await runWineserver(
            executable: runtime.wineserverExecutable,
            arguments: ["-w"],
            environment: env,
            timeout: .milliseconds(300)
        ) {
        case .exited:
            // wineserver -w exited immediately → no server running
            return false
        case .timedOut:
            // wineserver -w hung → server is active
            return true
        }
    }

    // MARK: - Private

    private func verifyPrefix(_ prefix: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw WineServerError.prefixNotFound(prefix)
        }
    }

    /// Run wineserver with a timeout, using async continuation.
    /// The probe process itself is terminated on timeout — the target
    /// wineserver is NOT affected.
    private func runWineserver(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> ProcessWaitOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WineServerError.wineserverNotFound(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()

        return await withTaskGroup(of: ProcessWaitOutcome.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { proc in
                        process.terminationHandler = nil
                        continuation.resume(returning: ProcessWaitOutcome.exited(proc.terminationStatus))
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                return ProcessWaitOutcome.timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()

            if case .timedOut = first {
                process.terminationHandler = nil
                process.terminate() // kill only the probe process
            }

            return first
        }
    }
}
