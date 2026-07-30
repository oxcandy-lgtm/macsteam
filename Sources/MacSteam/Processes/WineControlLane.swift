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

/// The parsed result of a `tasklist /FO CSV` command.
struct TasklistResult: Sendable {
    let rawLines: [String]
    let processes: [WindowsProcessSnapshot]
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
    /// - Returns: An array of `WindowsProcessSnapshot` entries.
    /// - Throws: `ProcessRunner.RunnerError` or `WineEnvironmentError`.
    func taskList(
        wineExecutable: URL,
        prefixURL: URL,
        runtimeURL: URL
    ) async throws -> [WindowsProcessSnapshot] {
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

        let processes = csvLines.compactMap { line -> WindowsProcessSnapshot? in
            parseTasklistCSVLine(line)
        }

        return processes
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
    /// - Throws: `ProcessRunner.RunnerError` or `WineEnvironmentError`.
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

        let _ = try await processRunner.run(
            executable: wineExecutable,
            arguments: arguments,
            environment: environment,
            workingDirectory: prefixURL,
            timeout: 30,
            mode: .waitForExit
        )
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
    /// - Throws: `ProcessRunner.RunnerError`.
    func wineserverKill(
        wineserverURL: URL,
        prefixURL: URL
    ) async throws {
        let environment = buildBasicWineEnvironment(prefixURL: prefixURL)
        let _ = try await processRunner.run(
            executable: wineserverURL,
            arguments: ["-k"],
            environment: environment,
            workingDirectory: prefixURL,
            timeout: 30,
            mode: .waitForExit
        )
    }

    // MARK: - wineserver -w

    /// Wait for the wineserver to shut down for the given prefix.
    ///
    /// - Parameters:
    ///   - wineserverURL: The resolved `wineserver` executable URL.
    ///   - prefixURL: The Wine prefix (WINEPREFIX) directory.
    ///   - timeoutSeconds: Maximum seconds to wait for shutdown.
    /// - Returns: `true` if wineserver exited cleanly, `false` on timeout or
    ///   signal termination.
    /// - Throws: `ProcessRunner.RunnerError` (not for timeout – see above).
    func wineserverWait(
        wineserverURL: URL,
        prefixURL: URL,
        timeoutSeconds: Int
    ) async throws -> Bool {
        let environment = buildBasicWineEnvironment(prefixURL: prefixURL)
        do {
            let _ = try await processRunner.run(
                executable: wineserverURL,
                arguments: ["-w"],
                environment: environment,
                workingDirectory: prefixURL,
                timeout: TimeInterval(timeoutSeconds),
                mode: .waitForExit
            )
            return true
        } catch let error as ProcessRunner.RunnerError {
            switch error {
            case .timeoutReached, .processTerminated, .cancelled, .pipeReadFailed:
                return false
            case .executableNotFound, .executableNotRegularFile, .alreadyRunning:
                throw error
            }
        }
    }

    // MARK: - Environment

    /// Build a full Wine environment using `WineLaunchEnvironmentBuilder`.
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
    private func parseTasklistCSVLine(_ line: String) -> WindowsProcessSnapshot? {
        let fields = parseCSVLine(line)
        guard fields.count >= 6 else { return nil }

        let imageName = fields[0]
        let pidStr = fields[1]
        let sessionName = fields[2]
        let sessionNumberStr = fields[3]
        let memUsageStr = fields[4]
        let status = fields[5]

        guard let pid = Int32(pidStr) else { return nil }
        guard let sessionNumber = Int(sessionNumberStr) else { return nil }

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
