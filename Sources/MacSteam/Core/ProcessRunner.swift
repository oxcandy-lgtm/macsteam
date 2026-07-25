// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Safe process execution with no shell involvement.
///
/// All processes are launched via `Process.executableURL` + `Process.arguments`.
/// `/bin/sh -c`, `sudo`, and string concatenation of user input are strictly
/// forbidden.
actor ProcessRunner {

    // MARK: - Public types

    struct ProcessResult: Equatable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    enum RunnerError: Error, LocalizedError, Equatable, Sendable {
        case executableNotFound(URL)
        case executableNotRegularFile(URL)
        case processTerminated(signal: Int32)
        case timeoutReached(TimeInterval)
        case cancelled
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(url):
                return "Executable not found at \(url.path)."
            case let .executableNotRegularFile(url):
                return "Path is not a regular executable file: \(url.path)."
            case let .processTerminated(signal):
                return "Process terminated by signal \(signal)."
            case let .timeoutReached(seconds):
                return "Process timed out after \(seconds)s."
            case .cancelled:
                return "Process was cancelled."
            case .alreadyRunning:
                return "A process is already running."
            }
        }
    }

    // MARK: - Run

    func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        // Verify executable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RunnerError.executableNotFound(executable)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw RunnerError.executableNotRegularFile(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Safe minimal environment
        let safeEnv = environment ?? [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": ProcessInfo.processInfo.userName
        ]
        process.environment = safeEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Handle timeout with a task
        if let timeoutSeconds = timeout {
            let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
            while process.isRunning {
                if ContinuousClock.now >= deadline {
                    process.terminate()
                    throw RunnerError.timeoutReached(timeoutSeconds)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } else {
            process.waitUntilExit()
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
