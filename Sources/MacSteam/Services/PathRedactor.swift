// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Privacy‑safe path transformer.
///
/// Converts real user paths to sanitised representations before
/// they enter logs or diagnostics output.
enum PathRedactor {

    /// Redact a path by replacing the user's home directory with `$HOME`.
    /// - Parameter path: The original path string.
    /// - Returns: A redacted path string.
    static func redactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.replacingOccurrences(of: home, with: "$HOME")
    }

    /// Mask email addresses in a string.
    static func maskEmails(_ text: String) -> String {
        let pattern = #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "***@***.***"
        )
    }

    /// Mask common token patterns (GitHub tokens, AWS keys, Bearer tokens).
    static func maskTokens(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]+"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"xox[baprs]-[A-Za-z0-9][A-Za-z0-9-]+"#,
            #"Bearer\s+[A-Za-z0-9._-]+"#,
            #"access_token[=:][A-Za-z0-9]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "***"
            )
        }
        return result
    }

    /// Mask or replace hostnames that look like real hosts.
    static func maskHostnames(_ text: String) -> String {
        // Simple heuristic: anything that looks like a hostname
        // (alphanumeric + hyphens) but is not localhost
        let pattern = #"\b([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.(local|lan|internal))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "*.redacted"
        )
    }

    /// Apply all redactions to a string.
    static func fullyRedact(_ text: String) -> String {
        var result = text
        result = redactPath(result)
        result = maskEmails(result)
        result = maskTokens(result)
        result = maskHostnames(result)
        return result
    }

    /// Check whether a string appears to contain a private key block.
    static func containsPrivateKey(_ text: String) -> Bool {
        let patterns = [
            "BEGIN PRIVATE KEY",
            "BEGIN RSA PRIVATE KEY",
            "BEGIN OPENSSH PRIVATE KEY",
            "BEGIN EC PRIVATE KEY"
        ]
        return patterns.contains { text.contains($0) }
    }
}
