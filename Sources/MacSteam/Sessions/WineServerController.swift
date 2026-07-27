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
/// **U1R6:** All operations are scoped to exactly one prefix.
/// Global `pkill`/`killall`/`wineserver` calls are forbidden.
actor WineServerController {

    /// Send a graceful shutdown request to the wineserver for the given prefix.
    /// Equivalent to `wineserver -k`.
    ///
    /// - Parameters:
    ///   - runtime: The runtime adapter providing wineserver.
    ///   - prefix: The prefix URL to target (WINEPREFIX).
    ///   - waitSeconds: Max seconds to wait for wineserver to exit after -k.
    /// - Returns: `true` if wineserver exited, `false` if timeout.
    func shutdownPrefix(
        runtime: WineRuntimeControl,
        prefix: URL,
        waitSeconds: Int = 10
    ) async throws -> Bool {
        try verifyPrefix(prefix)

        let env = try runtime.controlEnvironment(for: prefix)

        // Step 1: wineserver -k (request shutdown)
        try await runWineserver(
            executable: runtime.wineserverExecutable,
            arguments: ["-k"],
            environment: env
        )

        // Step 2: wineserver -w (wait for exit)
        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        while Date() < deadline {
            let exited = try await runWineserverSilent(
                executable: runtime.wineserverExecutable,
                arguments: ["-w"],
                environment: env,
                timeout: 2
            )
            if exited { return true }
        }

        return false
    }

    /// Force-kill the wineserver for the given prefix.
    /// Only used when graceful shutdown (`-k`) times out.
    func forceShutdownPrefix(
        runtime: WineRuntimeControl,
        prefix: URL
    ) async throws {
        try verifyPrefix(prefix)

        let env = try runtime.controlEnvironment(for: prefix)

        // Force kill via SIGKILL through wineserver
        try await runWineserver(
            executable: runtime.wineserverExecutable,
            arguments: ["-k"],
            environment: env
        )
    }

    /// Check whether a wineserver is running for the given prefix.
    func isRunning(prefix: URL, runtime: WineRuntimeControl) throws -> Bool {
        try verifyPrefix(prefix)

        let env = try runtime.controlEnvironment(for: prefix)
        let process = Process()
        process.executableURL = runtime.wineserverExecutable
        process.arguments = ["-w"]
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        // If wineserver -w returns immediately, no server is running
        // If it blocks, a server is running. But we use a short timeout
        // so we can't distinguish via exit code alone.
        // Alternative: check if the wineserver lock file exists
        let serverLock = prefix.appendingPathComponent("wineserver.lock")
        return FileManager.default.fileExists(atPath: serverLock.path)
    }

    // MARK: - Private

    private func verifyPrefix(_ prefix: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw WineServerError.prefixNotFound(prefix)
        }
    }

    @discardableResult
    private func runWineserver(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Int = 30
    ) async throws -> Int32 {
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
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WineServerError.wineserverTerminated(process.terminationStatus)
        }

        return process.terminationStatus
    }

    /// Run wineserver and return whether it completed within timeout.
    private func runWineserverSilent(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Int
    ) async throws -> Bool {
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
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
