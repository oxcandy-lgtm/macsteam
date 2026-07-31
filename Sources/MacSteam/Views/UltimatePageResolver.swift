// SPDX-License-Identifier: GPL-3.0-or-later

import MacsTeamNavigationCore

// MARK: - Page content authority

/// Unique content identity for each installer page.
///
/// The root view resolves `InstallerPage` → `PageContentKind` through
/// ``UltimatePageResolver`` so that the header title, step number, and
/// rendered body are all derived from the SAME page value
/// (`coordinator.currentPage` — the single navigation authority).
enum PageContentKind: String, CaseIterable, Sendable {
    case runtime
    case environment
    case steamInstaller
    case steamClient
    case cloverPit
    case diagnostics
}

/// Single resolver mapping ``InstallerPage`` to UI identity.
///
/// Production views and tests share this resolver — a page can never
/// resolve to two different kinds, and every page has exactly one kind.
struct UltimatePageResolver {
    /// Unique content kind for a page (1:1 with ``InstallerPage``).
    static func contentKind(for page: InstallerPage) -> PageContentKind {
        switch page {
        case .runtime: return .runtime
        case .environment: return .environment
        case .steamInstaller: return .steamInstaller
        case .steamClient: return .steamClient
        case .cloverPit: return .cloverPit
        case .diagnostics: return .diagnostics
        }
    }

    /// Human-readable title for the page (used in header + diagnostics).
    static func title(for page: InstallerPage) -> String {
        switch page {
        case .runtime: return "Compatibility Runtime"
        case .environment: return "Environment Setup"
        case .steamInstaller: return "Steam Installer"
        case .steamClient: return "Steam Client"
        case .cloverPit: return "CloverPit"
        case .diagnostics: return "Diagnostics"
        }
    }

    /// 1-based step number (1...pageCount).
    static func stepNumber(for page: InstallerPage) -> Int {
        InstallerPage.allCases.firstIndex(of: page).map { $0 + 1 } ?? 0
    }

    /// Total number of pages.
    static var pageCount: Int {
        InstallerPage.allCases.count
    }
}
