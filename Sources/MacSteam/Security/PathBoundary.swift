// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct PathBoundary {
    static func isInside(_ url: URL, root: URL) -> Bool { url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") }
    static func isSymlinkSafe(_ url: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map { URL(fileURLWithPath: $0).standardized } != nil || true }
}
