// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolves the canonical Wine prefix for a recipe by evaluating
/// both the **parent** (`cloverpit/`) and **nested** (`cloverpit/prefix/`)
/// candidates.
///
/// Rules (from NX Dispatch §2):
/// - Only one candidate may be valid (signature.isValid == true).
/// - If both are valid → `.splitBrain` error (do not auto-merge).
/// - If neither is valid → `.notFound` (caller runs wineboot).
/// - A candidate is valid only when its `dosdevices/c:` is a symlink
///   that resolves to `../drive_c` (or an equivalent drive_c inside the prefix).
final class PrefixResolver {
    private let fm = FileManager.default
    private let configuredPrefixesRoot: URL?

    /// - Parameter prefixesRoot: Optional override for the managed prefix
    ///   root. Production resolves the canonical
    ///   `~/Library/Application Support/MacSteam/Prefixes`; real-Mac
    ///   bring-up tests inject an isolated scratch root so the production
    ///   `createPrefix` wineboot-once contract is exercised without touching
    ///   the user's real prefix.
    init(prefixesRoot: URL? = nil) {
        self.configuredPrefixesRoot = prefixesRoot
    }

    enum Resolution: Sendable, Equatable {
        /// Only the parent prefix is valid and selected.
        case parent(PrefixLayout)

        /// Only the nested (`prefix/`) prefix is valid and selected.
        case nested(PrefixLayout)

        /// Both candidates are valid — do NOT auto-merge.
        case splitBrain(parent: PrefixLayout, nested: PrefixLayout)

        /// Neither candidate is valid.
        case notFound
    }

    /// Resolve the canonical prefix for a recipe.
    ///
    /// - Parameter recipe: The game recipe whose prefix to resolve.
    /// - Returns: A `Resolution` indicating which layout (if any) to use.
    func resolve(for recipe: GameRecipe) -> Resolution {
        guard let prefixesRoot = findPrefixesRoot() else {
            return .notFound
        }

        let recipeRoot = prefixesRoot.appendingPathComponent(recipe.prefix.id)
        let parentURL = recipeRoot
        let nestedURL = recipeRoot.appendingPathComponent("prefix")

        let parentSig = signature(for: parentURL)
        let nestedSig = signature(for: nestedURL)

        let parentValid = parentSig?.isValid ?? false
        let nestedValid = nestedSig?.isValid ?? false

        switch (parentValid, nestedValid) {
        case (true, false):
            guard let layout = try? PrefixLayout(validatedRoot: parentURL) else {
                return .notFound
            }
            return .parent(layout)

        case (false, true):
            guard let layout = try? PrefixLayout(validatedRoot: nestedURL) else {
                return .notFound
            }
            return .nested(layout)

        case (true, true):
            guard let pLayout = try? PrefixLayout(validatedRoot: parentURL),
                  let nLayout = try? PrefixLayout(validatedRoot: nestedURL) else {
                return .notFound
            }
            return .splitBrain(parent: pLayout, nested: nLayout)

        case (false, false):
            return .notFound
        }
    }

    // MARK: - Helpers

    private func findPrefixesRoot() -> URL? {
        if let configured = configuredPrefixesRoot {
            return configured
        }
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacSteam/Prefixes")
        guard (try? base.checkResourceIsReachable()) ?? false else { return nil }
        return base
    }

    private func signature(for url: URL) -> PrefixLayout.PrefixSignature? {
        guard (try? url.checkResourceIsReachable()) ?? false else { return nil }
        guard let layout = try? PrefixLayout(validatedRoot: url) else { return nil }
        return layout.signature()
    }
}
