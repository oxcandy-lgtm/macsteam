// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

/// Manages the RuntimeDependencies directory layout for a specific runtime.
///
/// The layout mirrors the structure needed by Wine at runtime:
/// ```
/// ~/Library/Application Support/MacSteam/RuntimeDependencies/<runtime-hash>/
///   ├── lib/
///   ├── fonts/
///   └── fontconfig/
/// ```
///
/// The runtime hash is the first 16 characters (8 bytes) of the SHA-256 digest
/// of the canonical runtime path. This provides a deterministic, collision-resistant
/// directory name without exposing the full path.
struct RuntimeDependencyLayout: Sendable {
    /// The root directory for this runtime's dependencies.
    let root: URL

    /// Creates a layout from a canonical runtime root path.
    ///
    /// - Parameter runtimePath: The canonical absolute path of the runtime root.
    ///   This is typically `ImportedWineRuntime.runtimeURL.path`.
    init?(runtimePath: String) {
        let hash = Self.computeHash(runtimePath)
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        self.root = appSupport
            .appendingPathComponent("MacSteam")
            .appendingPathComponent("RuntimeDependencies")
            .appendingPathComponent(hash)
    }

    /// The `lib/` subdirectory — used for `DYLD_LIBRARY_PATH`.
    func libDirectory() -> URL {
        root.appendingPathComponent("lib", isDirectory: true)
    }

    /// The `fonts/` subdirectory.
    func fontDirectory() -> URL {
        root.appendingPathComponent("fonts", isDirectory: true)
    }

    /// The `fontconfig/` subdirectory — used for `FONTCONFIG_PATH`.
    func fontconfigDirectory() -> URL {
        root.appendingPathComponent("fontconfig", isDirectory: true)
    }

    /// Ensure the `lib/`, `fonts/`, and `fontconfig/` directories exist on disk.
    func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: libDirectory(), withIntermediateDirectories: true)
        try fm.createDirectory(at: fontDirectory(), withIntermediateDirectories: true)
        try fm.createDirectory(at: fontconfigDirectory(), withIntermediateDirectories: true)
    }

    // MARK: - Private

    /// Returns the first 16 hex characters (8 bytes) of the SHA-256 digest
    /// of the given path string.
    private static func computeHash(_ path: String) -> String {
        let data = Data(path.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
