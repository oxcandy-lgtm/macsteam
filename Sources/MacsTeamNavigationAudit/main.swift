// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MacsTeamNavigationCore

@main
enum MacsTeamNavigationAudit {
    static func main() async {
        let auditor = InstallerNavigationAuditor()
        let report = await auditor.audit()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(report)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
        } catch {
            print("{\"error\": \"Failed to encode report: \(error.localizedDescription)\"}")
        }
    }
}
