// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolves Wine executable URLs from a runtime root directory,
/// supporting both standard and macOS bundle layouts.
///
/// Standard layout:
/// ```
/// <root>/bin/wine
/// <root>/bin/wineserver
/// <root>/bin/wineboot
/// <root>/bin/wine64         (optional)
/// ```
///
/// Bundle layout (used by some Wine distributions packaged as .app bundles):
/// ```
/// <root>/Contents/Resources/wine/bin/wine
/// <root>/Contents/Resources/wine/bin/wineserver
/// <root>/Contents/Resources/wine/bin/wineboot
/// <root>/Contents/Resources/wine/bin/wine64   (optional)
/// ```
///
/// Detection is automatic: the presence of `<root>/bin/wine` selects standard layout,
/// otherwise bundle layout is assumed.
struct WineExecutableLayout: Sendable {
    /// The two supported Wine executable layouts.
    enum LayoutType: Sendable {
        /// `<root>/bin/wine`
        case standard
        /// `<root>/Contents/Resources/wine/bin/wine`
        case bundle
    }

    /// The runtime root URL (symlink-resolved, validated).
    let root: URL

    /// Which layout was detected.
    let layoutType: LayoutType

    /// The `bin/` directory URL for the detected layout.
    var binDirectory: URL {
        switch layoutType {
        case .standard:
            return root.appendingPathComponent("bin", isDirectory: true)
        case .bundle:
            return root
                .appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true)
        }
    }

    /// Create a layout by probing the runtime root for known executable placements.
    ///
    /// - Parameter root: A validated runtime root URL
    ///   (typically `ImportedWineRuntime.runtimeURL`).
    init(root: URL) {
        self.root = root
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: root.appendingPathComponent("bin/wine").path) {
            self.layoutType = .standard
        } else {
            self.layoutType = .bundle
        }
    }

    /// Detect the layout from a runtime root URL and return a fully-configured
    /// `WineExecutableLayout`.
    ///
    /// - Parameter url: The runtime root URL to probe.
    /// - Returns: A layout configured for the detected structure.
    static func detect(from url: URL) -> WineExecutableLayout {
        WineExecutableLayout(root: url)
    }

    /// The `wine` executable URL.
    var wine: URL {
        binDirectory.appendingPathComponent("wine")
    }

    /// The `wineserver` executable URL.
    var wineserver: URL {
        binDirectory.appendingPathComponent("wineserver")
    }

    /// The `wine64` executable URL, if present.
    var wine64: URL? {
        let url = binDirectory.appendingPathComponent("wine64")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Returns the `wineboot` URL, creating a wrapper script if the real
    /// `wineboot` executable is absent.
    ///
    /// The wrapper is a short shell script that delegates to `wine wineboot`,
    /// which is the standard workaround for Wine builds where wineboot is
    /// not compiled as a standalone executable.
    ///
    /// - Throws: If the wrapper script cannot be written.
    @discardableResult
    func ensureWineboot() throws -> URL {
        let fm = FileManager.default
        let winebootURL = binDirectory.appendingPathComponent("wineboot")

        guard !fm.isExecutableFile(atPath: winebootURL.path) else {
            return winebootURL
        }

        // Create wrapper script invoking wine's built-in wineboot
        try fm.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )

        let wrapper = #"""
        #!/bin/sh
        exec "$(dirname "$0")/wine" wineboot "$@"
        """#
        try wrapper.write(to: winebootURL, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: winebootURL.path
        )
        return winebootURL
    }
}
