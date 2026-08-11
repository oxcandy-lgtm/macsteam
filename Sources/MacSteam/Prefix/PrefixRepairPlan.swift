// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A plan to repair a broken or corrupted Wine prefix for a given recipe.
struct PrefixRepairPlan {
    let recipeID: String
    let operations: [RepairOperation]
    let isDryRun: Bool

    /// Individual repair operations that can be performed on a prefix.
    enum RepairOperation {
        case recreateWinePrefix
        case reinstallSteam
        case restoreFromSnapshot(snapshotURL: URL)
        case resetRegistry
    }
}
