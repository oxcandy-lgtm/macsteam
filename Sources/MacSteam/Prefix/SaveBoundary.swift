// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Describes the save data boundary for a game — which paths contain game save data
/// and at what confidence level.
///
/// Maps to `Contracts/save-boundary.schema.json` (schema version 1).
struct SaveBoundary: Codable, Sendable, Equatable {
    /// Schema version identifier; must be 1.
    let schemaVersion: Int

    /// Identifier of the game whose save data boundaries are being described.
    let gameId: String

    /// Overall confidence level in the save boundary discovery.
    let confidence: Confidence

    /// Candidate save data paths with individual confidence levels.
    let candidates: [Candidate]

    /// Absolutely confirmed save data paths.
    let confirmedPaths: [String]

    /// Whether the discovery process failed.
    let failedDiscovery: Bool

    /// ISO 8601 timestamp when this save boundary was determined.
    let discoveredAt: String

    // MARK: - Nested types

    enum Confidence: String, Codable, Sendable {
        case unknown
        case speculative
        case confirmed
        case verified
    }

    struct Candidate: Codable, Sendable, Equatable {
        let relativePath: String
        let confidence: CandidateConfidence
        let description: String
    }

    enum CandidateConfidence: String, Codable, Sendable {
        case speculative
        case confirmed
    }

    // MARK: - Coding keys

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameId
        case confidence
        case candidates
        case confirmedPaths
        case failedDiscovery
        case discoveredAt
    }
}
