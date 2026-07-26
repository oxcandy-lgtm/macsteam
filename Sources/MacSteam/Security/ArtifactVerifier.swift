// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

struct ArtifactVerifier {
    static func sha256(data: Data) -> String { SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined() }
    static func sha256(url: URL) throws -> String { let d = try Data(contentsOf: url); return sha256(data: d) }
    static func verify(data: Data, expectedSHA256: String) -> Bool { sha256(data: data) == expectedSHA256 }
}
