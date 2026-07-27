// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A candidate runtime discovered during system inspection.
public struct RuntimeCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let runtimeType: RuntimeType
    public let url: URL?
    public let inspection: RuntimeInspection?
    let runtime: (any CompatibilityRuntime)?

    public static func == (lhs: RuntimeCandidate, rhs: RuntimeCandidate) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.runtimeType == rhs.runtimeType
    }

    init(
        id: String,
        displayName: String,
        runtimeType: RuntimeType,
        url: URL?,
        inspection: RuntimeInspection?,
        runtime: (any CompatibilityRuntime)?
    ) {
        self.id = id
        self.displayName = displayName
        self.runtimeType = runtimeType
        self.url = url
        self.inspection = inspection
        self.runtime = runtime
    }
}

/// Priority-ordered type of runtime.
public enum RuntimeType: String, Sendable, CaseIterable, Comparable {
    case managedWine
    case importedWine
    case systemWine
    case crossover

    public static func < (lhs: RuntimeType, rhs: RuntimeType) -> Bool {
        Self.priorityOrder[lhs] ?? 99 < Self.priorityOrder[rhs] ?? 99
    }

    private static let priorityOrder: [RuntimeType: Int] = [
        .managedWine: 0,
        .importedWine: 1,
        .systemWine: 2,
        .crossover: 3,
    ]
}

/// Discovers and selects compatibility runtimes in priority order.
///
/// Priority (lowest index wins):
/// 1. `ManagedWineRuntime` — MacsTeam bundled Wine (Coming later)
/// 2. `ImportedWineRuntime` — user-selected Wine directory
/// 3. `SystemWineRuntime` — Homebrew/MacPorts Wine
/// 4. `CrossOverRuntime` — optional third-party commercial runtime
///
/// CrossOver is **never** selected ahead of any Wine runtime.
/// CrossOver absence never blocks app startup or runtime selection UI.
@MainActor
final class RuntimeRegistry {
    private let fm = FileManager.default

    /// Discover all available runtimes on the system.
    /// Returns candidates sorted by priority (lowest-first).
    func discover() async -> [RuntimeCandidate] {
        var candidates: [RuntimeCandidate] = []

        // 1. ManagedWineRuntime (Coming later — skip for now)
        // candidates.append(contentsOf: discoverManagedWine())

        // 2. ImportedWineRuntime — scan user's ImportedRuntimes directory
        candidates.append(contentsOf: discoverImportedWine())

        // 3. SystemWineRuntime — probe standard Homebrew/MacPorts paths
        if let sys = discoverSystemWine() {
            candidates.append(sys)
        }

        // 4. CrossOverRuntime — optional commercial adapter
        if let co = discoverCrossOver() {
            candidates.append(co)
        }

        return candidates.sorted { $0.runtimeType < $1.runtimeType }
    }

    /// Select the preferred runtime from candidates, respecting priority.
    /// Returns `nil` only when no usable runtime exists.
    func selectPreferred(from candidates: [RuntimeCandidate]) -> RuntimeCandidate? {
        let usable = candidates.filter { $0.inspection?.isUsable == true }
        // Within usable candidates, respect priority order
        return usable.min { $0.runtimeType < $1.runtimeType }
    }

    /// Locate runtime at a user-selected URL (imported Wine).
    func locateUserSelected(at url: URL) -> RuntimeCandidate? {
        guard let runtime = ImportedWineRuntime(url: url) else { return nil }
        let inspection = runtime.inspect()
        return RuntimeCandidate(
            id: ImportedWineRuntime.runtimeID,
            displayName: "Imported Wine (\(url.lastPathComponent))",
            runtimeType: .importedWine,
            url: url,
            inspection: inspection,
            runtime: runtime
        )
    }

    /// Validate a previously selected runtime URL is still valid.
    func validateStored(_ candidate: RuntimeCandidate) -> Bool {
        guard let runtime = candidate.runtime else { return false }
        do {
            try runtime.validate()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private discovery

    private func discoverImportedWine() -> [RuntimeCandidate] {
        let importedDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/ImportedRuntimes")

        guard let contents = try? fm.contentsOfDirectory(
            at: importedDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { dir in
            guard let runtime = ImportedWineRuntime(url: dir) else { return nil }
            let inspection = runtime.inspect()
            return RuntimeCandidate(
                id: "\(ImportedWineRuntime.runtimeID)-\(dir.lastPathComponent)",
                displayName: inspection.isUsable ? "Imported Wine (\(dir.lastPathComponent))" : "Broken Import (\(dir.lastPathComponent))",
                runtimeType: .importedWine,
                url: dir,
                inspection: inspection,
                runtime: runtime
            )
        }
    }

    private func discoverSystemWine() -> RuntimeCandidate? {
        let probePaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
        ]
        for path in probePaths {
            let url = URL(fileURLWithPath: path)
            let wineExe = url.appendingPathComponent("wine")
            guard fm.isExecutableFile(atPath: wineExe.path) else { continue }
            guard let runtime = SystemWineRuntime(url: url) else { continue }
            let inspection = runtime.inspect()
            return RuntimeCandidate(
                id: SystemWineRuntime.runtimeID,
                displayName: "System Wine (\(path))",
                runtimeType: .systemWine,
                url: url,
                inspection: inspection,
                runtime: runtime
            )
        }
        return nil
    }

    private func discoverCrossOver() -> RuntimeCandidate? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/CrossOver.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/CrossOver.app"),
        ]
        for url in candidates {
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let runtime = CrossOverRuntime(url: url) else { continue }
            let inspection = runtime.inspect()
            return RuntimeCandidate(
                id: CrossOverRuntime.runtimeID,
                displayName: "CrossOver",
                runtimeType: .crossover,
                url: url,
                inspection: inspection,
                runtime: runtime
            )
        }
        return nil
    }
}
