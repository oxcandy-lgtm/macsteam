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

    /// Whether this type is a free / open-source Wine runtime.
    var isOpenSource: Bool {
        switch self {
        case .managedWine, .importedWine, .systemWine: true
        case .crossover: false
        }
    }

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
/// 4. `CrossOverRuntime` — optional commercial runtime (disabled by default)
///
/// **U1R6:** Commercial runtimes (CrossOver) are disabled by default.
/// They are never auto-detected unless the user explicitly opts in via
/// `CommercialRuntimePolicy.explicitUserOptIn`.
///
/// CrossOver absence never blocks app startup or runtime selection UI.
/// CrossOver is never recommended, never auto-selected, and never treated
/// as the only available option.
@MainActor
final class RuntimeRegistry {
    private let fm = FileManager.default
    var commercialPolicy: CommercialRuntimePolicy

    /// Persisted preferred runtime ID (set after user selection).
    /// On startup, this runtime is restored first before fallback discovery.
    var preferredRuntimeID: String?

    /// U1 period: exclude System Wine from Steam launch/runtime selection.
    /// Set to true until WineCX10 is the default.
    var excludeSystemWine: Bool

    init(commercialPolicy: CommercialRuntimePolicy = .disabled,
         preferredRuntimeID: String? = nil,
         excludeSystemWine: Bool = true) {
        self.commercialPolicy = commercialPolicy
        self.preferredRuntimeID = preferredRuntimeID
        self.excludeSystemWine = excludeSystemWine
    }

    // MARK: - Discovery

    /// Discover all **open-source** Wine runtimes on the system.
    /// These are always eligible for automatic selection.
    func discoverOpenSourceRuntimes() async -> [RuntimeCandidate] {
        var candidates: [RuntimeCandidate] = []

        // 1. ManagedWineRuntime (Coming later — skip for now)
        // candidates.append(contentsOf: discoverManagedWine())

        // 2. ImportedWineRuntime — scan user's ImportedRuntimes directory
        candidates.append(contentsOf: discoverImportedWine())

        // 3. SystemWineRuntime — probe standard Homebrew/MacPorts paths
        if let sys = discoverSystemWine() {
            candidates.append(sys)
        }

        return candidates.sorted { $0.runtimeType < $1.runtimeType }
    }

    /// Discover **commercial** Wine runtimes (e.g. CrossOver).
    /// Only called when `commercialPolicy == .explicitUserOptIn`.
    func discoverCommercialRuntimes() async -> [RuntimeCandidate] {
        guard commercialPolicy == .explicitUserOptIn else { return [] }
        var candidates: [RuntimeCandidate] = []

        if let co = discoverCrossOver() {
            candidates.append(co)
        }

        return candidates.sorted { $0.runtimeType < $1.runtimeType }
    }

    /// Discover all runtimes the current policy allows.
    /// Open-source always included; commercial only with explicit opt-in.
    func discover() async -> [RuntimeCandidate] {
        var candidates = await discoverOpenSourceRuntimes()
        candidates.append(contentsOf: await discoverCommercialRuntimes())
        return candidates
    }

    // MARK: - Selection

    /// Select the preferred runtime from candidates, respecting priority.
    /// Only considers **open-source** runtimes unless commercial policy
    /// explicitly allows them.
    /// Returns `nil` only when no usable runtime exists.
    func selectPreferred(from candidates: [RuntimeCandidate]) -> RuntimeCandidate? {
        var pool = candidates

        // Filter out commercial runtimes unless explicitly opted in
        if commercialPolicy != .explicitUserOptIn {
            pool = pool.filter { $0.runtimeType.isOpenSource }
        }

        // U1 period: exclude System Wine (confirmed CEF black screen)
        if excludeSystemWine {
            pool = pool.filter { $0.runtimeType != .systemWine }
        }

        let usable = pool.filter { $0.inspection?.isUsable == true }

        // If preferredRuntimeID is set and found, return it
        if let preferredID = preferredRuntimeID {
            if let preferred = usable.first(where: { $0.id == preferredID }) {
                return preferred
            }
            // Preferred runtime not found — don't silently fallback
            return nil
        }

        return usable.min { $0.runtimeType < $1.runtimeType }
    }

    /// Whether the given candidate is eligible for automatic selection
    /// under the current policy.
    func isEligible(_ candidate: RuntimeCandidate) -> Bool {
        if candidate.runtimeType.isOpenSource { return true }
        return commercialPolicy == .explicitUserOptIn
    }

    // MARK: - User-selected runtime

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
