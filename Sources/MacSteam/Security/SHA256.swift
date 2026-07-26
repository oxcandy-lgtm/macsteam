// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

struct SHA256Hash {
    static func compute(_ data: Data) -> String { SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined() }
}
