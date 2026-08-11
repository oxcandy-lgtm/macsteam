// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Persistent binding between a runtime and a prefix.
///
/// Stored atomically on disk. Only relative entry names are saved
/// (e.g. "WineCX10.bundle", "cloverpit-winecx10-test"), not absolute paths.
struct RuntimePrefixBinding: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let runtimeEntryName: String
    let runtimeSafeID: String
    let prefixEntryName: String
    let prefixSafeID: String
    let createdAt: Date
    let updatedAt: Date
}

/// Manages persistent storage and validation of runtime-prefix binding.
actor RuntimePrefixBindingStore {
    private let fm = FileManager.default

    private var stateDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/State")
    }

    private var bindingURL: URL {
        stateDir.appendingPathComponent("runtime-prefix-binding.json")
    }

    /// Save a binding atomically.
    func save(_ binding: RuntimePrefixBinding) throws {
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(binding)
        let tempURL = stateDir.appendingPathComponent("binding-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        _ = try? fm.replaceItemAt(bindingURL, withItemAt: tempURL,
                                  backupItemName: nil, options: .withoutDeletingBackupItem)
        try? fm.removeItem(at: tempURL)
    }

    /// Load the saved binding, if any.
    func load() -> RuntimePrefixBinding? {
        guard let data = try? Data(contentsOf: bindingURL) else { return nil }
        return try? JSONDecoder().decode(RuntimePrefixBinding.self, from: data)
    }

    /// Validate that the saved binding is still valid on disk.
    /// Returns the binding only if runtime root and prefix root are both present
    /// and their hashes match the saved safe IDs.
    func validate() -> RuntimePrefixBinding? {
        guard let binding = load() else { return nil }
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam")

        let runtimeRoot = support.appendingPathComponent("ImportedRuntimes/\(binding.runtimeEntryName)")
        let prefixRoot = support.appendingPathComponent("Prefixes/\(binding.prefixEntryName)")

        guard fm.fileExists(atPath: runtimeRoot.path),
              fm.fileExists(atPath: prefixRoot.path) else { return nil }

        // Verify safe IDs match (quick hash check)
        guard computeSafeID(runtimeRoot.path) == binding.runtimeSafeID,
              computeSafeID(prefixRoot.path) == binding.prefixSafeID else { return nil }

        return binding
    }

    /// Delete the saved binding.
    func clear() {
        try? fm.removeItem(at: bindingURL)
    }

    private func computeSafeID(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["shasum", "-a", "256", path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(output.prefix(12))
    }
}
