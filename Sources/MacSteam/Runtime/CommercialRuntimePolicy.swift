// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Policy controlling whether commercial (third-party) Wine runtimes
/// are eligible for automatic discovery and selection.
///
/// Per U1R6, the default is `.disabled`: commercial runtimes are never
/// auto-detected or preferred. The user must explicitly opt in.
enum CommercialRuntimePolicy: String, Sendable, Codable, CaseIterable {
    /// Commercial runtimes are completely excluded from discovery.
    /// No auto-detection, no auto-selection, no recommendation.
    case disabled

    /// Commercial runtimes are discoverable but only after the user
    /// explicitly enables them in Advanced settings.
    /// They remain at the lowest priority (below all open-source Wine).
    case explicitUserOptIn
}
