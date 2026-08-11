// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Canonical prefix layout derived from a validated root URL.
///
/// Every component uses this struct instead of reconstructing prefix paths
/// from `NSHomeDirectory()` or string concatenation.
struct PrefixLayout: Sendable, Equatable {
    /// The validated prefix root directory.
    let root: URL

    /// `drive_c` — the Windows C: drive inside the prefix.
    let driveC: URL

    /// `dosdevices` — DOS device symlinks.
    let dosdevices: URL

    /// `system.reg` — system registry hive.
    let systemReg: URL

    /// `user.reg` — user registry hive.
    let userReg: URL

    /// Known Windows Steam installation locations inside the prefix.
    let windowsSteamCandidates: [URL]
}

// MARK: - Factory

extension PrefixLayout {
    /// Validates `root` and, on success, returns a fully-populated `PrefixLayout`.
    ///
    /// - Parameter root: A candidate prefix root URL (must already exist).
    /// - Throws: `PrefixLayoutError` if validation fails.
    init(validatedRoot root: URL) throws {
        guard root.isFileURL else {
            throw PrefixLayoutError.invalidRoot("Not a file URL")
        }
        guard (try? root.checkResourceIsReachable()) ?? false else {
            throw PrefixLayoutError.notFound(root)
        }

        self.root = root
        driveC = root.appendingPathComponent("drive_c")
        dosdevices = root.appendingPathComponent("dosdevices")
        systemReg = root.appendingPathComponent("system.reg")
        userReg = root.appendingPathComponent("user.reg")

        windowsSteamCandidates = [
            driveC.appendingPathComponent("Program Files (x86)/Steam"),
            driveC.appendingPathComponent("Program Files/Steam"),
        ]
    }
}

// MARK: - Diagnostics

extension PrefixLayout {
    /// Basic health of the two most vital prefix paths.
    struct PrefixSignature: Sendable, Equatable {
        let directoryExists: Bool
        let systemRegRegularFile: Bool
        let userRegRegularFile: Bool
        let driveCDirectory: Bool
        let dosdevicesDirectory: Bool
        let dosdevicesCSymlink: Bool
        let dosdevicesCResolvesToDriveC: Bool
        let steamExePresent: Bool

        var isValid: Bool {
            directoryExists
            && systemRegRegularFile
            && userRegRegularFile
            && driveCDirectory
            && dosdevicesDirectory
            && dosdevicesCSymlink
            && dosdevicesCResolvesToDriveC
        }
    }

    /// Compute the prefix signature for this layout.
    func signature() -> PrefixSignature {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        // The root itself
        let rootExists = fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue

        // drive_c
        isDir = false
        let dcExists = fm.fileExists(atPath: driveC.path, isDirectory: &isDir) && isDir.boolValue

        // dosdevices
        isDir = false
        let ddExists = fm.fileExists(atPath: dosdevices.path, isDirectory: &isDir) && isDir.boolValue

        // dosdevices/c: symlink
        let cLink = dosdevices.appendingPathComponent("c:")
        let cLinkIsSymlink = ((try? fm.destinationOfSymbolicLink(atPath: cLink.path)) != nil)

        // Does c: resolve to ../drive_c or an absolute path to the prefix's drive_c?
        var cResolvesToDriveC = false
        if cLinkIsSymlink, let dest = try? fm.destinationOfSymbolicLink(atPath: cLink.path) {
            let resolved: URL
            if (dest as NSString).isAbsolutePath {
                resolved = URL(fileURLWithPath: dest).standardized
            } else {
                resolved = URL(fileURLWithPath: dosdevices.path + "/" + dest).standardized
            }
            cResolvesToDriveC = (resolved.path == driveC.path)
        }

        // Reg files
        let sregOk = (try? systemReg.checkResourceIsReachable()) ?? false
        let uregOk = (try? userReg.checkResourceIsReachable()) ?? false

        // Steam exe
        let steamExe = windowsSteamCandidates.first { candidate in
            let exe = candidate.appendingPathComponent("steam.exe")
            return fm.isExecutableFile(atPath: exe.path)
        }
        let steamPresent = (steamExe != nil)

        return PrefixSignature(
            directoryExists: rootExists,
            systemRegRegularFile: sregOk,
            userRegRegularFile: uregOk,
            driveCDirectory: dcExists,
            dosdevicesDirectory: ddExists,
            dosdevicesCSymlink: cLinkIsSymlink,
            dosdevicesCResolvesToDriveC: cResolvesToDriveC,
            steamExePresent: steamPresent
        )
    }
}

// MARK: - Errors

enum PrefixLayoutError: LocalizedError, Sendable {
    case invalidRoot(String)
    case notFound(URL)
    case splitBrain(URL, URL)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let msg):
            return "Invalid prefix root: \(msg)"
        case .notFound(let url):
            return "Prefix root not found: \(url.path)"
        case .splitBrain(let a, let b):
            return "Split-brain prefix: both \(a.path) and \(b.path) are valid"
        }
    }
}
