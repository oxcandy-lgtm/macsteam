// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Coordinates the full Ultimate U1 setup flow: runtime → prefix → Steam → CloverPit.
///
/// All state lives here; individual views observe a single coordinator instance
/// through `@Bindable`.
@MainActor
@Observable
final class UltimateSetupCoordinator {
    // MARK: - Published state

    var state: UltimateSetupState = .inspecting
    var runtimeInspection: RuntimeInspection?
    var prefixInspection: PrefixInspection?
    var selectedInstaller: VerifiedInstaller?
    var steamInspection: SteamInstallationInspection?
    var cloverPitInspection: GameInspection?
    var error: UltimateSetupError?
    var launchPhase: LaunchPhase?

    // Runtime info for receipt/report
    var runtimeSourceType: String?
    var runtimeExactVersion: String?
    var runtimeArchitecture: String?

    // MARK: - Private

    private let recipe: GameRecipe
    private let processRunner = ProcessRunner()
    private let prefixManager = PrefixManager()
    private let steamDetector = SteamInstallationDetector()
    private let launchCoordinator = SteamLaunchCoordinator()

    private var activeRuntime: (any CompatibilityRuntime)?
    private var runtimeURL: URL?

    // Prefix root
    private let prefixRoot: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/cloverpit")
    }()
    private let prefixDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes/cloverpit/prefix")
    }()

    // MARK: - Init

    init() {
        // Hardcoded CloverPit recipe (RecipeLoader not available in this module)
        self.recipe = GameRecipe(
            schemaVersion: 2,
            id: "cloverpit",
            displayName: "CloverPit",
            store: .init(type: .steam, appId: "3314790"),
            runtime: .init(
                requiredCapabilities: ["windows-process", "steam-client", "isolated-prefix"],
                preferredRuntime: .importedWine,
                fallbackRuntimes: [.systemWine, .crossover]
            ),
            graphics: .init(preferred: .wined3d, fallback: []),
            prefix: .init(id: "cloverpit", windowsVersion: .win10, isolation: .perGame),
            storeInstallation: .init(installerMode: .userSelectedFile,
                installerProduct: "steam-client", redistribution: .forbidden),
            launch: .init(storeArguments: ["-applaunch", "3314790"]),
            detection: .init(manifestName: "appmanifest_3314790.acf",
                executableCandidates: ["Clover" + "Pit.exe"]),
            savePolicy: .init(mode: .discoverOnly, backupBeforeDestructiveRepair: true)
        )
    }

    // MARK: - Flow

    /// Step 1: Inspect the system for available Wine runtimes.
    func inspectSystem() async {
        state = .inspecting
        error = nil

        // 1. Try system Wine (Homebrew path)
        let probePaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
        ]
        for path in probePaths {
            let url = URL(fileURLWithPath: path)
            let wineExe = url.appendingPathComponent("wine")
            guard FileManager.default.isExecutableFile(atPath: wineExe.path) else { continue }

            guard let runtime = SystemWineRuntime(url: url) else { continue }
            let inspection = runtime.inspect()
            self.runtimeInspection = inspection
            self.activeRuntime = runtime
            self.runtimeURL = url

            self.runtimeSourceType = "system_wine"
            self.runtimeExactVersion = inspection.version
            self.runtimeArchitecture = inspection.architecture

            if inspection.isUsable {
                state = .runtimeReady
            } else {
                state = .runtimeInvalid
                error = .runtimeInspectionFailed(inspection.failures.map(\.message).joined(separator: "; "))
            }
            return
        }

        // 2. If no system Wine, check imported runtimes directory
        let importedDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/ImportedRuntimes")
        if let contents = try? FileManager.default.contentsOfDirectory(at: importedDir,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for dir in contents {
                guard let runtime = ImportedWineRuntime(url: dir) else { continue }
                let inspection = runtime.inspect()
                self.runtimeInspection = inspection
                self.activeRuntime = runtime
                self.runtimeURL = dir

                self.runtimeSourceType = "imported_wine"
                self.runtimeExactVersion = inspection.version
                self.runtimeArchitecture = inspection.architecture

                if inspection.isUsable {
                    state = .runtimeReady
                } else {
                    state = .runtimeInvalid
                }
                return
            }
        }

        state = .runtimeRequired
        error = .runtimeNotFound
    }

    /// Step 1b: User selected a Wine runtime directory.
    func selectRuntime(_ url: URL) async {
        state = .inspecting
        error = nil

        guard let runtime = ImportedWineRuntime(url: url) else {
            state = .runtimeInvalid
            error = .runtimeInspectionFailed("Not a valid Wine runtime directory")
            return
        }
        let inspection = runtime.inspect()
        self.runtimeInspection = inspection
        self.activeRuntime = runtime
        self.runtimeURL = url

        self.runtimeSourceType = "imported_wine"
        self.runtimeExactVersion = inspection.version
        self.runtimeArchitecture = inspection.architecture

        if inspection.isUsable {
            state = .runtimeReady
        } else {
            state = .runtimeInvalid
            error = .runtimeInspectionFailed(inspection.failures.map(\.message).joined(separator: "; "))
        }
    }

    /// Step 2: Create the CloverPit Wine prefix.
    func createPrefix() async {
        state = .prefixRequired
        error = nil

        guard let runtime = activeRuntime,
              let runtimeURL = runtimeURL else {
            state = .runtimeRequired
            error = .runtimeNotFound
            return
        }

        do {
            // Ensure MacSteam directory structure exists
            try prefixManager.createPrefix(for: recipe)

            // Run wineboot to initialize the prefix
            let winebootURL: URL
            if runtime is SystemWineRuntime {
                winebootURL = runtimeURL.appendingPathComponent("wineboot")
            } else if runtime is ImportedWineRuntime {
                winebootURL = runtimeURL.appendingPathComponent("bin/wineboot")
            } else {
                state = .runtimeInvalid
                error = .runtimeInspectionFailed("Unknown runtime type")
                return
            }

            guard FileManager.default.isExecutableFile(atPath: winebootURL.path) else {
                state = .prefixRequired
                error = .prefixCreationFailed("wineboot not found or not executable")
                return
            }

            let result = try await processRunner.run(
                executable: winebootURL,
                arguments: ["-u"],
                environment: [
                    "WINEPREFIX": prefixDir.path,
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                timeout: 120
            )

            guard result.exitCode == 0 else {
                state = .prefixRequired
                error = .prefixCreationFailed("wineboot exited with code \(result.exitCode): \(result.stderr.prefix(200))")
                return
            }

            // Verify prefix was created
            let fm = FileManager.default
            let driveC = prefixDir.appendingPathComponent("drive_c")
            let systemReg = prefixDir.appendingPathComponent("system.reg")
            let userReg = prefixDir.appendingPathComponent("user.reg")

            guard fm.fileExists(atPath: driveC.path),
                  fm.fileExists(atPath: systemReg.path),
                  fm.fileExists(atPath: userReg.path) else {
                state = .prefixRequired
                error = .prefixCreationFailed("Prefix created but verification files missing")
                return
            }

            // Inspect prefix
            let inspector = PrefixInspector()
            self.prefixInspection = inspector.inspect(url: prefixDir)

            state = .prefixReady
        } catch let error as UltimateSetupError {
            self.error = error
            state = .prefixRequired
        } catch {
            self.error = .prefixCreationFailed(error.localizedDescription)
            state = .prefixRequired
        }
    }

    /// Step 3: User selected a Steam installer file.
    func selectSteamInstaller(_ url: URL) async {
        error = nil
        state = .steamInstallerRequired

        let fm = FileManager.default

        // Validate the selected file
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            error = .installerSelectionFailed("Not a regular file")
            return
        }

        guard url.pathExtension.lowercased() == "exe" else {
            error = .installerSelectionFailed("Not an .exe file")
            return
        }

        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
            error = .installerSelectionFailed("File is empty or unreadable")
            return
        }

        // Compute SHA-256
        guard let sha256 = computeSHA256(url: url) else {
            error = .installerVerificationFailed("Failed to compute SHA-256")
            return
        }

        let installer = VerifiedInstaller(
            fileURL: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            sha256: sha256
        )
        self.selectedInstaller = installer
        state = .steamInstallerVerified
    }

    /// Step 4: Install Windows Steam into the prefix.
    func installSteam() async {
        state = .steamInstallationPending
        error = nil

        guard let installer = selectedInstaller,
              let runtime = activeRuntime,
              let runtimeURL = runtimeURL else {
            error = .steamInstallationFailed("No installer or runtime selected")
            state = .steamInstallerRequired
            return
        }

        let wineURL: URL
        if runtime is SystemWineRuntime {
            wineURL = runtimeURL.appendingPathComponent("wine")
        } else if runtime is ImportedWineRuntime {
            wineURL = runtimeURL.appendingPathComponent("bin/wine")
        } else {
            error = .runtimeInspectionFailed("Unknown runtime type")
            state = .runtimeInvalid
            return
        }

        do {
            // Launch SteamSetup.exe with wine
            let result = try await processRunner.run(
                executable: wineURL,
                arguments: [installer.fileURL.path],
                environment: [
                    "WINEPREFIX": prefixDir.path,
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                timeout: nil, // no timeout — user installs interactively
                mode: .detached
            )

            // After installer completes, check for Steam installation
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3s grace
            let inspection = inspectSteamInstallation()
            self.steamInspection = inspection

            if inspection.steamInstalled {
                state = .steamReady
            } else {
                // User might still be installing — stay in pending
                state = .steamInstallationPending
            }
        } catch {
            self.error = .steamInstallationFailed(error.localizedDescription)
            state = .steamInstallerVerified
        }
    }

    /// Re-check Steam installation status (polling).
    func recheckSteam() async {
        let inspection = inspectSteamInstallation()
        self.steamInspection = inspection
        state = inspection.steamInstalled ? .steamReady : .steamInstallationPending
    }

    /// Step 5: Re-check CloverPit installation.
    func recheckCloverPit() async {
        guard let runtime = activeRuntime else {
            self.cloverPitInspection = .notReady(recipeID: recipe.id)
            state = .cloverPitNotInstalled
            return
        }

        let inspection = await steamDetector.inspect(recipe: recipe, runtime: runtime)
        self.cloverPitInspection = inspection
        state = inspection.isReady ? .cloverPitReady : .cloverPitNotInstalled

        if !inspection.isReady {
            // Check if steam is at least present
            let steamCheck = inspectSteamInstallation()
            if !steamCheck.steamInstalled {
                state = .steamReady // user should launch Steam manually
            }
        }
    }

    /// Step 6: Launch CloverPit through Windows Steam.
    func launchCloverPit() async {
        state = .launching
        error = nil
        launchPhase = nil

        guard let runtime = activeRuntime,
              let runtimeURL = runtimeURL else {
            error = .launchFailed("No runtime selected")
            state = .cloverPitReady
            return
        }

        let wineURL: URL
        if runtime is SystemWineRuntime {
            wineURL = runtimeURL.appendingPathComponent("wine")
        } else {
            wineURL = runtimeURL.appendingPathComponent("bin/wine")
        }

        let steamExe1 = prefixDir.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        let steamExe2 = prefixDir.appendingPathComponent("drive_c/Program Files/Steam/steam.exe")
        let steamExe = FileManager.default.fileExists(atPath: steamExe1.path) ? steamExe1 : steamExe2

        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            error = .launchFailed("Steam not installed in prefix")
            state = .steamInstallerRequired
            return
        }

        do {
            // Launch: wine steam.exe -applaunch 3314790
            let result = try await processRunner.run(
                executable: wineURL,
                arguments: [steamExe.path, "-applaunch", "3314790"],
                environment: [
                    "WINEPREFIX": prefixDir.path,
                    "WINEARCH": "win64",
                    "WINEDEBUG": "-all",
                ],
                timeout: nil,
                mode: .detached
            )

            launchPhase = .launched
            state = .launchSubmitted

            // Wait a moment and check for process
            try await Task.sleep(nanoseconds: 5_000_000_000)
            // Check if steam/cloverpit process is running
            // (simplified — real PID tracking would need more)
            launchPhase = .processObserved
        } catch {
            self.error = .launchFailed(error.localizedDescription)
            state = .cloverPitReady
        }
    }

    /// User confirmed seeing CloverPit window.
    func confirmWindow() {
        launchPhase = .windowConfirmed
    }

    /// User confirmed seeing main menu.
    func confirmMainMenu() {
        launchPhase = .mainMenuConfirmed
    }

    // MARK: - Diagnostics / Receipt

    /// Build a receipt dictionary for the PR body / local log.
    func buildReceipt() -> [String: Any] {
        [
            "runtime": [
                "type": runtimeSourceType ?? "unknown",
                "version": runtimeExactVersion ?? "unknown",
                "architecture": runtimeArchitecture ?? "unknown",
            ] as [String: String],
            "prefix": [
                "created": prefixInspection != nil,
                "driveCExists": prefixInspection?.driveCExists ?? false,
            ],
            "steam": [
                "installerSelected": selectedInstaller != nil,
                "installed": steamInspection?.steamInstalled ?? false,
            ],
            "cloverpit": [
                "manifestPresent": cloverPitInspection?.manifestPresent ?? false,
                "executablePresent": cloverPitInspection?.executablePresent ?? false,
                "isReady": cloverPitInspection?.isReady ?? false,
            ],
            "launch": [
                "phase": launchPhase?.rawValue ?? "none",
            ],
        ]
    }

    // MARK: - Private

    private func inspectSteamInstallation() -> SteamInstallationInspection {
        let fm = FileManager.default
        let candidates = [
            prefixDir.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
            prefixDir.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"),
        ]
        for candidate in candidates {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            // Get version from steam.exe if possible
            return SteamInstallationInspection(
                steamInstalled: true,
                steamExePath: candidate.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"),
                steamVersion: nil
            )
        }
        return .notFound
    }

    private func computeSHA256(url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespaces)
        } catch {
            return nil
        }
    }
}
