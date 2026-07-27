// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Zero-knowledge redactor for Steam-sensitive content.
///
/// The redactor never stores the sensitive value before rejection.
/// It only records that redaction was applied, the category, and
/// a boolean count.  No hashes, no partial values.
struct SteamLogRedactor: Sendable {

    /// Outcome of a single redaction check.
    struct Result: Sendable, Equatable {
        let applied: Bool
        let category: SteamSensitiveCategory?
        let redactedLength: Int

        static let clean = Result(applied: false, category: nil, redactedLength: 0)
    }

    /// Inspects a string for sensitive patterns and returns the redaction outcome.
    /// The original value is never copied into the result.
    static func redact(_ input: String, category: SteamSensitiveCategory? = nil) -> Result {
        let categories: [SteamSensitiveCategory] = category.map { [$0] } ?? SteamSensitiveCategory.allCases
        for cat in categories {
            if matches(input: input, category: cat) {
                return Result(applied: true, category: cat, redactedLength: input.utf8.count)
            }
        }
        return .clean
    }

    /// Inspects a URL path against the path deny list.
    static func redactURL(_ url: URL) -> Result {
        if SteamPathDenylist.isDenied(url) {
            return Result(applied: true, category: .authenticationFile, redactedLength: url.path.utf8.count)
        }
        // Check for sensitive filenames
        let filename = url.lastPathComponent
        if SteamSensitiveDataPolicy.isSensitive(url) {
            return Result(applied: true, category: .authenticationFile, redactedLength: url.path.utf8.count)
        }
        return .clean
    }

    // MARK: - Private

    private static func matches(input: String, category: SteamSensitiveCategory) -> Bool {
        let lower = input.lowercased()
        switch category {
        case .accountIdentifier:
            // Steam account name patterns (does not store the match)
            return lower.hasPrefix("steam") || lower.contains("candy_") || lower.contains("user_")
        case .password:
            return lower.contains("password") || lower.contains("passwd")
        case .steamGuard:
            return lower.contains("steamguard") || lower.contains("guard_code")
        case .sessionToken:
            return lower.contains("session") || lower.contains("token") && !lower.contains("tokenizer")
        case .cookie:
            return lower.contains("cookie") && !lower.contains("cookiecut")
        case .machineAuthorization:
            return lower.contains("machineauth") || lower.contains("ssfn")
        case .authenticationFile:
            return lower.contains("loginusers") || lower.contains("config.vdf")
        case .browserProfile:
            return lower.contains("local storage") || lower.contains("session storage") || lower.contains("indexeddb")
        case .crashMemoryDump:
            return lower.hasSuffix(".dmp") || lower.hasSuffix(".mdmp") || lower.hasSuffix(".core")
        }
    }
}

/// A redaction counter that tracks aggregate statistics.
actor SteamRedactionCounter {
    private var counts: [SteamSensitiveCategory: Int] = [:]
    private var totalApplied = 0

    func record(_ result: SteamLogRedactor.Result) {
        guard result.applied, let category = result.category else { return }
        counts[category, default: 0] += 1
        totalApplied += 1
    }

    func snapshot() -> (total: Int, byCategory: [SteamSensitiveCategory: Int]) {
        (totalApplied, counts)
    }

    func reset() {
        counts = [:]
        totalApplied = 0
    }
}
