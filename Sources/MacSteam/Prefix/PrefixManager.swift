// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Manages Wine prefix lifecycle: creation, location, destruction, and safety validation.
struct PrefixManager {
    /// Root directory for runtime engines (Wine, CrossOver, etc.).
    let runtimesRoot: URL

    /// Root directory for game-specific Wine prefixes.
    let prefixesRoot: URL

    /// Root directory for operation receipts (install/repair logs).
    let receiptsRoot: URL

    // MARK: - Initialization

    /// Creates the managed directory structure under `~/Library/Application Support/MacSteam/`.
    init() {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam")
        runtimesRoot = base.appendingPathComponent("Runtimes")
        prefixesRoot = base.appendingPathComponent("Prefixes")
        receiptsRoot = base.appendingPathComponent("Receipts")

        let fm = FileManager.default
        for dir in [runtimesRoot, prefixesRoot, receiptsRoot] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Prefix lifecycle

    /// Creates the directory structure for a new Wine prefix for the given recipe.
    /// - Parameter recipe: The game recipe to create a prefix for.
    /// - Throws: File manager errors if directories cannot be created.
    func createPrefix(for recipe: GameRecipe) throws {
        let url = prefixURL(for: recipe)
        let fm = FileManager.default

        // Create the prefix root
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        // Create standard Wine prefix subdirectories
        let subdirs = [
            "drive_c",
            "drive_c/Program Files",
            "drive_c/Program Files (x86)",
            "drive_c/users",
            "drive_c/windows",
            "drive_c/windows/system32",
            "drive_c/windows/syswow64",
            "dosdevices",
        ]
        for sub in subdirs {
            try fm.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }

        // Create a marker file so inspectors can identify this as a MacSteam prefix
        let marker = url.appendingPathComponent(".macsteam-prefix")
        try "\(recipe.prefix.id)".write(to: marker, atomically: true, encoding: .utf8)
    }

    /// Returns the expected prefix URL for a given recipe.
    func prefixURL(for recipe: GameRecipe) -> URL {
        prefixesRoot.appendingPathComponent(recipe.prefix.id).appendingPathComponent("prefix")
    }

    /// Destroys a prefix directory after safety validation.
    /// - Parameters:
    ///   - recipe: The recipe whose prefix should be destroyed.
    ///   - force: If `true`, skip safety validation and delete unconditionally.
    /// - Throws: `PrefixError` or file manager errors.
    func destroyPrefix(for recipe: GameRecipe, force: Bool) throws {
        let url = prefixURL(for: recipe)
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw PrefixError.prefixNotFound(url)
        }

        if !force {
            try validatePrefixSafety(url)
        }

        try fm.removeItem(at: url)

        // Also clean up empty parent directory
        let parent = url.deletingLastPathComponent()
        if let contents = try? fm.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
            try? fm.removeItem(at: parent)
        }
    }

    /// Validates that a prefix URL is safe to delete — checks symlink safety
    /// and that the canonical path is inside the managed prefixes root.
    /// - Parameter url: The prefix URL to validate.
    /// - Throws: `PrefixError` if validation fails.
    func validatePrefixSafety(_ url: URL) throws {
        let canonical = url.resolvingSymlinksInPath()
        let allowed = prefixesRoot.resolvingSymlinksInPath()

        guard canonical.path.hasPrefix(allowed.path + "/") || canonical.path == allowed.path else {
            throw PrefixError.outsideManagedRoot(url)
        }

        // Check that the path does not traverse through any symlinks
        var components: [String] = []
        var temp = url.path
        while temp != "/" {
            components.append(temp)
            temp = (temp as NSString).deletingLastPathComponent
        }
        components.append("/")

        for path in components.reversed() {
            let checkURL = URL(fileURLWithPath: path)
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: checkURL.path) {
                let resolved = URL(fileURLWithPath: dest, relativeTo: checkURL.deletingLastPathComponent()).standardized
                guard resolved.path.hasPrefix(allowed.path) else {
                    throw PrefixError.symlinkEscape(url)
                }
            }
        }
    }
}

// MARK: - Errors

enum PrefixError: LocalizedError, Sendable {
    case prefixNotFound(URL)
    case outsideManagedRoot(URL)
    case symlinkEscape(URL)
    case creationFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .prefixNotFound(let url):
            return "Prefix not found at \(url.path)"
        case .outsideManagedRoot(let url):
            return "Prefix at \(url.path) is outside the managed prefixes root"
        case .symlinkEscape(let url):
            return "Symlink escape detected at \(url.path)"
        case .creationFailed(let url, let reason):
            return "Failed to create prefix at \(url.path): \(reason)"
        }
    }
}
