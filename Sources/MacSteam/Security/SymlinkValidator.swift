// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct SymlinkValidator {
    static func validate(url: URL, allowedRoot: URL) throws {
        // Check if file is a symlink
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attrs[.type] as? FileAttributeType, type != .typeSymbolicLink else {
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let resolved = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardized
            guard resolved.path.hasPrefix(allowedRoot.standardized.path) else {
                throw NSError(domain: "SymlinkEscape", code: 1, userInfo: [NSLocalizedDescriptionKey: "Symlink escapes allowed root"])
            }
            return
        }
    }
}
