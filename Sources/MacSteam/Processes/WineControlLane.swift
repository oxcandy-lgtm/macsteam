// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A snapshot of a Windows process as reported by Wine's `tasklist`.
struct WindowsProcessSnapshot: Sendable, Equatable {
    let imageName: String
    let pid: Int32
    let sessionName: String
    let sessionNumber: Int
    let memUsageKB: UInt64
    let status: String
}

/// Describes why a single CSV line could not be parsed.
struct TasklistParseError: Sendable, Error {
    let line: String
    let reason: String
}

/// The parsed result of a `tasklist /FO CSV` command.
struct TasklistResult: Sendable {
    let rawLines: [String]
    let processes: [WindowsProcessSnapshot]
    let parseErrors: [TasklistParseError]
}

/// Serializes ALL short-lived Wine control commands (tasklist, taskkill,
/// wineserver -k, wineserver -w) through an actor to prevent concurrent
/// interference with the Wine runtime.
enum WineControlError: Error, LocalizedError {
    case tasklistFailed(exitCode: Int32, stderr: String)
    case terminateFailed(image: String, exitCode: Int32)
    case wineserverFailed(exitCode: Int32)
    case invalidCSV(String)

    var errorDescription: String? {
        switch self {
        case .tasklistFailed(let code, let stderr):
            return "tasklist failed (exit \(code)): \(stderr)"
        case .terminateFailed(let image, let code):
            return "taskkill \(image) failed (exit \(code))"
        case .wineserverFailed(let code):
            return "wineserver command failed (exit \(code))"
        case .invalidCSV(let line):
            return "Invalid CSV line: \(line)"
        }
    }
}

/// Interface for serializing Wine control commands (tasklist, terminate,
/// wineserver kill/wait) through a serial executor to prevent concurrent
/// interference with the Wine runtime.
protocol WineControlServicing: Sendable {
    /// Run `wine tasklist` and parse the output.
    func taskList(wineExecutable: URL, prefixURL: URL, runtimeURL: URL) async throws -> TasklistResult

    /// Terminate a Windows process by image name.
    func terminate(imageName: String, force: Bool, wineExecutable: URL, prefixURL: URL, runtimeURL: URL) async throws

    /// Kill the wineserver process for the given prefix.
    func wineserverKill(wineserverURL: URL, prefixURL: URL) async throws

    /// Wait for the wineserver to shut down.
    func wineserverWait(wineserverURL: URL, prefixURL: URL, timeoutSeconds: Int) async throws -> Bool
    func wineserverProbe(wineserverURL: URL, prefixURL: URL) async throws -> Bool
}

actor WineControlLane {

    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    // MARK: - tasklist

    /// Run `wine tasklist /FO CSV` and parse the output into structured snapshots.
    ///
    /// The caller is expected to resolve the wine executable via
    /// `WineExecutableLayout` before invoking this method.
    ///
    /// - Parameters:
    ///   - wineExecutable: The resolved `wine` executable URL.
    ///   - prefixURL: The Wine prefix (WINEPREFIX) directory.
    ///   - runtimeURL: The Wine runtime root, used for environment setup.
    /// - Returns: A `TasklistResult` containing parsed processes and any
    ///   parse errors encountered.
    /// - Throws: `ProcessRunner.RunnerError` or `WineEnvironmentError`.
    func taskList(
        wineExecutable: URL,
        prefixURL: URL,
        runtimeURL: URL
    ) async throws -> TasklistResult {
        let environment = try buildWineEnvironment(prefixURL: prefixURL, runtimeURL: runtimeURL)
        let result = try await processRunner.run(
            executable: wineExecutable,
            arguments: ["tasklist", "/V", "/FO", "CSV", "/NH"],
            environment: environment,
            workingDirectory: prefixURL,
            timeout: 30,
            mode: .waitForExit
        )

        guard result.exitCode == 0 else {
            throw WineControlError.tasklistFailed(exitCode: result.exitCode,
                                                   stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let rawLines = result.stdout
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !$0.isEmpty }

        // /NH suppresses the CSV header, so no dropFirst needed
        let csvLines = rawLines

        var processes: [WindowsProcessSnapshot] = []
        processes.reserveCapacity(csvLines.count)
        var parseErrors: [TasklistParseError] = []

        for line in csvLines {
            do {
                let snapshot = try parseTasklistCSVLine(line)
                processes.append(snapshot)
            } catch let error as TasklistParseError {
                parseErrors.append(error)
            } catch {
                // Unexpected — all parse failures produce TasklistParseError
                parseErrors.append(TasklistParseError(line: line, reason: "Unexpected error: \(error.localizedDescription)"))
            }
        }

        return TasklistResult(
            rawLines: rawLines,
            processes: processes,
            parseErrors: parseErrors
        )
    }

    // MARK: - terminate

    /// Terminate a Windows process by image name using `taskkill`.
    ///
    /// - Parameters:
    ///   - imageName: The image name to terminate (e.g. `"steam.exe"`).
    ///   - force: When `true`, passes `/F` for forceful termination.
    ///   - wineExecutable: The resolved `wine` executable URL.
    ///   - prefixURL: The Wine prefix (WINEPREFIX) directory.
    ///   - runtimeURL: The Wine runtime root, used for environment setup.
    /// - Throws: `WineControlError.terminateFailed` if exit code is non-zero,
    ///   `ProcessRunner.RunnerError` or `WineEnvironmentError`.
    func terminate(
        imageName: String,
        force: Bool,
        wineExecutable: URL,
        prefixURL: URL,
        runtimeURL: URL
    ) async throws {
        let environment = try buildWineEnvironment(prefixURL: prefixURL, runtimeURL: runtimeURL)
        var arguments: [String] = ["taskkill"]
        if force {
            arguments.append("/F")
        }
        arguments.append(contentsOf: ["/IM", imageName])

        let result = try await processRunner.run(
            executable: wineExecutable,
            arguments: arguments,
            environment: environment,
            workingDirectory: prefixURL,
            timeout: 30,
            mode: .waitForExit
        )

        guard result.exitCode == 0 else {
            throw WineControlError.terminateFailed(image: imageName, exitCode: result.exitCode)
        }
    }

    // MARK: - wineserver -k

    /// Kill the wineserver process for the given prefix.
    ///
    /// Uses a minimal Wine environment (WINEPREFIX, WINEARCH, WINEDEBUG)
    /// since a full dependency layout is not needed for the server binary.
    ///
    /// - Parameters:
    ///   - wineserverURL: The resolved `wineserver` executable URL.
    ///   - prefixURL: The Wine prefix (WINEPREFIX) directory.
    /// - Throws: `WineControlError.wineserverFailed` if exit code is non-zero,
    ///   `ProcessRunner.RunnerError`.
    func wineserverKill(
        wineserverURL: URL,
        prefixURL: URL
    ) async throws {
        let environment = buildBasicWineEnvironment(prefixURL: prefixURL)
        let result = try await processRunner.run(
            executable: wineserverURL,
            arguments: ["-k"],
            environment: environment,
            workingDirectory: prefixURL,
            timeout: 30,
            mode: .waitForExit
        )

        guard result.exitCode == 0 else {
            throw WineControlError.wineserverFailed(exitCode: result.exitCode)
        }
    }

    // MARK: - wineserver -w

    /// Wait for the wineserver to shut down for the given prefix.
    ///
    /// - Parameters:
    ///   - wineserverURL: The resolved `wineserver` executable URL.
    ///   - prefixURL: The Wine prefix (WINEPREFIX) directory.
    ///   - timeoutSeconds: Maximum seconds to wait for shutdown.
    /// - Returns: `true` if wineserver exited cleanly (exit code 0).
    /// - Throws: `WineControlError.wineserverFailed` if the exit code is
    ///   non-zero; `ProcessRunner.RunnerError` if the runner itself fails
    ///   (e.g. executable not found).
    func wineserverWait(
        wineserverURL: URL,
        prefixURL: URL,
        timeoutSeconds: Int
    ) async throws -> Bool {
        let environment = buildBasicWineEnvironment(prefixURL: prefixURL)
        do {
            let result = try await processRunner.run(
                executable: wineserverURL,
                arguments: ["-w"],
                environment: environment,
                workingDirectory: prefixURL,
                timeout: TimeInterval(timeoutSeconds),
                mode: .waitForExit
            )

            guard result.exitCode == 0 else {
                throw WineControlError.wineserverFailed(exitCode: result.exitCode)
            }
            return true
        } catch let error as WineControlError {
            throw error
        } catch let error as ProcessRunner.RunnerError {
            switch error {
            case .timeoutReached, .processTerminated, .cancelled, .pipeReadFailed, .ownershipLost, .signalFailed, .multipleWaiters, .cleanupRequired:
                return false
            case .executableNotFound, .executableNotRegularFile, .alreadyRunning:
                throw error
            }
        }
    }

    // MARK: - wineserver probe

    func wineserverProbe(wineserverURL: URL, prefixURL: URL) async throws -> Bool {
        let environment = buildBasicWineEnvironment(prefixURL: prefixURL)
        let result = try await processRunner.run(
            executable: wineserverURL,
            arguments: ["-p"],
            environment: environment,
            workingDirectory: prefixURL,
            timeout: 5,
            mode: .waitForExit
        )
        guard result.exitCode == 0 else {
            throw WineControlError.wineserverFailed(exitCode: result.exitCode)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !output.isEmpty
    }

    // MARK: - Environment
    ///
    /// Falls back to a basic environment when `RuntimeDependencyLayout`
    /// cannot be created for the given runtime path.
    private func buildWineEnvironment(prefixURL: URL, runtimeURL: URL) throws -> [String: String] {
        if let depLayout = RuntimeDependencyLayout(runtimePath: runtimeURL.path) {
            let builder = try WineLaunchEnvironmentBuilder(
                winePrefix: prefixURL,
                dependencyLayout: depLayout
            )
            return builder.build()
        }
        return buildBasicWineEnvironment(prefixURL: prefixURL)
    }

    /// Build a minimal Wine environment without dependency paths.
    private func buildBasicWineEnvironment(prefixURL: URL) -> [String: String] {
        [
            "WINEPREFIX": prefixURL.path,
            "WINEARCH": "win64",
            "WINEDEBUG": "-all",
        ]
    }

    // MARK: - CSV Parsing

    /// Parse a single line of `tasklist /FO CSV` output.
    ///
    /// Expected format:
    /// ```
    /// "Image Name","PID","Session Name","Session#","Mem Usage","Status"
    /// ```
    ///
    /// `Mem Usage` contains values like `"24 K"`, `"16,928 K"` or `"1,024,432 K"`.
    ///
    /// - Throws: `TasklistParseError` when the line cannot be parsed.
    private func parseTasklistCSVLine(_ line: String) throws -> WindowsProcessSnapshot {
        let fields = parseCSVLine(line)
        guard fields.count >= 6 else {
            throw TasklistParseError(line: line, reason: "expected at least 6 fields, got \(fields.count)")
        }

        let imageName = fields[0]
        let pidStr = fields[1]
        let sessionName = fields[2]
        let sessionNumberStr = fields[3]
        let memUsageStr = fields[4]
        let status = fields[5]

        guard let pid = Int32(pidStr) else {
            throw TasklistParseError(line: line, reason: "invalid PID '\(pidStr)'")
        }
        guard let sessionNumber = Int(sessionNumberStr) else {
            throw TasklistParseError(line: line, reason: "invalid session number '\(sessionNumberStr)'")
        }

        // Strip " K" suffix and thousands-separator commas
        let memUsageClean = memUsageStr
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " K", with: "")
            .replacingOccurrences(of: ",", with: "")
        let memUsageKB = UInt64(memUsageClean) ?? 0

        return WindowsProcessSnapshot(
            imageName: imageName,
            pid: pid,
            sessionName: sessionName,
            sessionNumber: sessionNumber,
            memUsageKB: memUsageKB,
            status: status
        )
    }

    /// Parse a single CSV line into fields, handling quoted fields properly.
    ///
    /// Supports fields wrapped in `"..."` which may contain embedded commas.
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            switch char {
            case "\"":
                inQuotes.toggle()
            case ",":
                if inQuotes {
                    current.append(char)
                } else {
                    fields.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}

extension WineControlLane: WineControlServicing {}
