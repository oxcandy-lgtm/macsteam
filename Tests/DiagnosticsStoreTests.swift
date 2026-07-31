// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct DiagnosticsStoreTests {

    @Test func storesEntries() {
        let store = DiagnosticsStore()
        store.append("Test entry")
        let entries = store.recentEntries()
        #expect(entries.count == 1)
        #expect(entries[0].message == "Test entry")
    }

    @Test func capsAtMaxEntries() {
        let store = DiagnosticsStore()
        for i in 0..<200 {
            store.append("Entry \(i)")
        }
        let entries = store.recentEntries()
        #expect(entries.count <= 100)
    }

    @Test func redactsPathsBeforeStoring() {
        let store = DiagnosticsStore()
        let home = NSHomeDirectory()
        store.append("Path: \(home)/Library/Logs")
        let entries = store.recentEntries()
        #expect(!entries[0].message.contains(home))
        #expect(entries[0].message.contains("$HOME"))
    }

    @Test func clearRemovesAllEntries() {
        let store = DiagnosticsStore()
        store.append("Entry 1")
        store.append("Entry 2")
        store.clear()
        #expect(store.recentEntries().isEmpty)
    }

    @Test func entryHasTimestamp() {
        let store = DiagnosticsStore()
        store.append("Test")
        let entry = store.recentEntries()[0]
        let diff = Date().timeIntervalSince(entry.timestamp)
        #expect(diff < 2)
    }
}
