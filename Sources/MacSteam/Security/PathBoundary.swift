// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Path safety checker using canonical URL component comparison.
///
/// Uses `.standardized.pathComponents` instead of `hasPrefix` on path
/// strings to avoid false positives from partial component matches
/// (e.g. `/Users/foo` matching `/Users/foobar`).
struct PathBoundary {
    /// Returns true if `url` is inside `root` using canonical path component
    /// comparison. Both URLs are standardized and symlinks resolved.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardized
        let resolvedRoot = root.resolvingSymlinksInPath().standardized
        let urlComponents = resolvedURL.pathComponents
        let rootComponents = resolvedRoot.pathComponents
        guard rootComponents.count <= urlComponents.count else { return false }
        return zip(rootComponents, urlComponents).allSatisfy(==)
    }

    /// Returns true if the file at `url` is a safe symlink (does not escape
    /// the allowed root).
    static func isSymlinkSafe(_ url: URL, allowedRoot: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink else {
            return true // not a symlink, safe
        }
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let resolved = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardized
        let allowed = allowedRoot.resolvingSymlinksInPath().standardized
        let destComponents = resolved.pathComponents
        let allowedComponents = allowed.pathComponents
        guard allowedComponents.count <= destComponents.count else { return false }
        return zip(allowedComponents, destComponents).allSatisfy(==)
    }
}
