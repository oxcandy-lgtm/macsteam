// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of attempting a session recovery.
enum SessionRecoveryResult: Sendable, Equatable {
    /// Receipt exists + server running → adopted.
    case adopted(state: GameSessionState)
    /// Receipt exists but server stopped → receipt removed.
    case staleReceiptRemoved
    /// No receipt → idle.
    case noReceipt
    /// Receipt missing but server running → orphan detected.
    case orphanDetected(prefixID: String)
    /// Recovery is not possible.
    case unrecoverable(String)
}

/// Checks for and recovers sessions after app restart/crash.
///
/// **U1R7:** Does NOT auto-launch Steam or any game.
/// Does NOT allow automatic launch when an orphan is detected.
struct SessionRecovery {

    /// Attempt to recover sessions for all known prefixes.
    /// Returns the first recoverable result for a given prefix.
    static func recover(
        prefix: URL,
        runtimeControl: WineRuntimeControl,
        receiptStore: SessionReceiptStore
    ) async -> SessionRecoveryResult {
        let receipt = receiptStore.read(prefix: prefix)

        // Check if wineserver is running
        let wineserverController = WineServerController()
        let serverRunning: Bool
        do {
            serverRunning = try await wineserverController.isRunning(
                prefix: prefix,
                runtime: runtimeControl
            )
        } catch {
            return .unrecoverable("Could not probe wineserver: \(error.localizedDescription)")
        }

        switch (receipt, serverRunning) {
        case (.some, true):
            // Receipt exists AND server running → adopt
            return .adopted(state: .runningUnknown)

        case (.some, false):
            // Receipt exists but server stopped → stale
            receiptStore.remove(prefix: prefix)
            return .staleReceiptRemoved

        case (.none, true):
            // Server running but no receipt → orphan
            let prefixID = (try? SessionLock.derivePrefixID(prefix)) ?? "unknown"
            return .orphanDetected(prefixID: prefixID)

        case (.none, false):
            // Nothing to recover
            return .noReceipt
        }
    }
}
