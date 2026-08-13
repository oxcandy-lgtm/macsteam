// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ApplicationServices
import Vision
import ScreenCaptureKit
import Darwin

/// Bounded, machine-readable snapshot of a visible Steam error. `present` is
/// the single most important field: the terminal reads what is ACTUALLY on the
/// user's screen (or in the process/log evidence), never a guess after a
/// timeout. Permission deficits are reported explicitly (`permission_required`),
/// never silently treated as "no error".
public struct ControlPlaneVisibleError: Codable, Equatable, Sendable {
    public var present: Bool
    /// "accessibility" | "window_title" | "ocr" | "stderr" | "steam_log"
    public var source: String?
    public var title: String?
    public var message: String?
    public var code: String?
    /// "accessibility" | "screen_recording" when a read could not be performed.
    public var permission_required: String?

    public init(
        present: Bool,
        source: String? = nil,
        title: String? = nil,
        message: String? = nil,
        code: String? = nil,
        permission_required: String? = nil
    ) {
        self.present = present
        self.source = source
        self.title = title
        self.message = message
        self.code = code
        self.permission_required = permission_required
    }
}

/// One structured error/warning line read from Steam's own generic logs.
/// Raw paths, PIDs, and account identity are never present (redacted).
public struct ControlPlaneSteamLogEntry: Codable, Equatable, Sendable {
    public var source: String
    public var component: String
    public var severity: String
    public var message: String

    public init(source: String, component: String, severity: String, message: String) {
        self.source = source
        self.component = component
        self.severity = severity
        self.message = message
    }
}

/// A single live window probe (geometry-filtered, layer-0, alpha>0). PIDs are
/// debugging-only and MUST NOT be emitted into control-plane JSON or reports.
public struct SteamWindowProbe: Sendable, Equatable {
    public var ownerPID: Int32
    public var ownerName: String
    public var title: String?
    public var windowID: Int32
    public var frame: CGRect
    public var isOnscreen: Bool
}

/// Result of a read-only Accessibility extraction.
public struct SteamAXRead: Sendable, Equatable {
    public var available: Bool
    public var title: String?
    public var messages: [String]
    public var permissionDenied: Bool

    public init(
        available: Bool,
        title: String? = nil,
        messages: [String] = [],
        permissionDenied: Bool = false
    ) {
        self.available = available
        self.title = title
        self.messages = messages
        self.permissionDenied = permissionDenied
    }
}

/// Result of an owned-window OCR extraction.
public struct SteamOCRRead: Sendable, Equatable {
    public var available: Bool
    public var texts: [String]
    public var permissionDenied: Bool

    public init(available: Bool, texts: [String] = [], permissionDenied: Bool = false) {
        self.available = available
        self.texts = texts
        self.permissionDenied = permissionDenied
    }
}

/// Live, read-only Steam observability: on-screen window text (Accessibility /
/// OCR / window metadata) and Steam's own generic log errors. Every read is
/// ownership-bounded (only caller-provided owned PIDs are ever inspected) and
/// every text is redacted + length-bounded before it may reach a control-plane
/// surface. No clicks, no typing, no operations.
public enum SteamLiveDiagnostics {

    // MARK: - Window enumeration

    /// Every window with valid geometry (layer 0, alpha > 0, non-degenerate
    /// bounds). Enumerates ALL windows — Wine windows report
    /// `kCGWindowIsOnscreen == false` even when genuinely visible, so
    /// on-screen filtering happens per-window on placement, never at
    /// enumeration time.
    public static func allWindows() -> [SteamWindowProbe] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var probes: [SteamWindowProbe] = []
        probes.reserveCapacity(raw.count)
        for row in raw {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid > 0 else { continue }
            guard let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0 else { continue }
            guard let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0 else { continue }
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            guard rect.width > 0, rect.height > 0 else { continue }
            probes.append(SteamWindowProbe(
                ownerPID: pid,
                ownerName: (row[kCGWindowOwnerName as String] as? String) ?? "",
                title: (row[kCGWindowName as String] as? String),
                windowID: (row[kCGWindowNumber as String] as? NSNumber)?.int32Value ?? 0,
                frame: rect,
                isOnscreen: (row[kCGWindowIsOnscreen as String] as? Bool) ?? false
            ))
        }
        return probes
    }

    /// Windows whose owner name or title contains the word "Steam".
    public static func steamCandidates(in windows: [SteamWindowProbe]) -> [SteamWindowProbe] {
        windows.filter { probe in
            if containsWord(probe.ownerName, "Steam") { return true }
            if let title = probe.title, containsWord(title, "Steam") { return true }
            return false
        }
    }

    /// Is this window placed where a human on an active display can see it?
    public static func isOnDisplay(_ probe: SteamWindowProbe) -> Bool {
        if probe.isOnscreen { return true }
        guard probe.frame.width > 0, probe.frame.height > 0 else { return false }
        for display in activeDisplayRects() {
            let intersection = display.intersection(probe.frame)
            if intersection.width > 0 && intersection.height > 0 {
                return true
            }
        }
        return false
    }

    public static func activeDisplayRects() -> [CGRect] {
        var rects: [CGRect] = []
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &displays, &displayCount)
        let count = min(Int(displayCount), displays.count)
        for index in 0..<count {
            let bounds = CGDisplayBounds(displays[index])
            rects.append(CGRect(origin: bounds.origin, size: bounds.size))
        }
        if rects.isEmpty {
            let main = CGDisplayBounds(CGMainDisplayID())
            rects.append(CGRect(origin: main.origin, size: main.size))
        }
        return rects
    }

    // MARK: - Ownership grounding

    /// Canonical (symlink-resolved) executable path of a PID, or nil.
    public static func canonicalExecutablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let data = Data(buffer.map { UInt8(bitPattern: $0) })
        guard let nulIndex = data.firstIndex(of: 0), nulIndex > 0 else { return nil }
        let path = String(decoding: data[..<nulIndex], as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Steam windows owned by a process whose canonical executable lives under
    /// one of the given prefix roots (identity-path grounding, not name
    /// matching).
    public static func prefixGroundedSteamWindows(prefixRoots: [String]) -> [SteamWindowProbe] {
        let normalized = prefixRoots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let probes = steamCandidates(in: allWindows())
        var result: [SteamWindowProbe] = []
        for probe in probes {
            guard let canonical = canonicalExecutablePath(of: probe.ownerPID) else { continue }
            let norm = URL(fileURLWithPath: canonical).resolvingSymlinksInPath().path
            if normalized.contains(where: { norm.hasPrefix($0) }) {
                result.append(probe)
            }
        }
        return result
    }

    // MARK: - Layer C1/C2: window metadata + Accessibility (read-only)

    /// Read window titles (C1) and Accessibility text (C2) of owned windows.
    /// Read-only: never clicks, never types, never activates.
    public static func readAccessibility(ownerPIDs: [Int32]) -> SteamAXRead {
        var title: String?
        var messages: [String] = []
        var seen = Set<String>()
        var permissionDenied = false

        for pid in ownerPIDs {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            switch error {
            case .success:
                break
            case .apiDisabled, .notImplemented, .cannotComplete, .failure:
                permissionDenied = true
                continue
            default:
                continue
            }
            guard let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                    let text = titleValue as? String, !text.isEmpty {
                    if title == nil {
                        title = text
                    } else if title != text {
                        record(text, into: &messages, seen: &seen)
                    }
                }
                collectStaticText(
                    in: window,
                    depth: 0,
                    maxDepth: 4,
                    into: &messages,
                    seen: &seen,
                    permissionDenied: &permissionDenied
                )
            }
        }

        return SteamAXRead(
            available: !(title == nil && messages.isEmpty),
            title: title,
            messages: messages,
            permissionDenied: permissionDenied
        )
    }

    private static func collectStaticText(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        into messages: inout [String],
        seen: inout Set<String>,
        permissionDenied: inout Bool
    ) {
        guard depth <= maxDepth else { return }
        var childrenValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        switch error {
        case .success:
            break
        case .apiDisabled, .notImplemented, .cannotComplete, .failure:
            permissionDenied = true
            return
        default:
            return
        }
        guard let children = childrenValue as? [AXUIElement], !children.isEmpty else { return }

        for child in children {
            var roleValue: CFTypeRef?
            let role = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success
                ? (roleValue as? String)
                : nil
            if role == "AXStaticText" || role == "AXDialog" || role == "AXSheet" {
                for attribute in [kAXValueAttribute as CFString, kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString] {
                    var textValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, attribute, &textValue) == .success,
                        let text = textValue as? String, !text.isEmpty {
                        record(text, into: &messages, seen: &seen)
                    }
                }
            }
            if messages.count >= 20 { return }
            collectStaticText(
                in: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                into: &messages,
                seen: &seen,
                permissionDenied: &permissionDenied
            )
        }
    }

    private static func record(_ text: String, into messages: inout [String], seen: inout Set<String>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !seen.contains(trimmed) else { return }
        seen.insert(trimmed)
        messages.append(redact(trimmed, maxLength: 200))
        if messages.count > 20 {
            messages = Array(messages.prefix(20))
        }
    }

    // MARK: - Layer C3: owned-window OCR fallback (read-only)

    /// OCR the ON-SCREEN content of owned windows with the local Vision engine.
    /// Bounded to owned windows only; the capture is in-memory and never
    /// persisted. Reports `permission_required: "screen_recording"` when the
    /// WindowServer refuses the capture (no screen-recording permission).
    public static func readOCR(ownerPIDs: [Int32]) async -> SteamOCRRead {
        let ownedSet = Set(ownerPIDs)
        let windows = allWindows().filter { ownedSet.contains($0.ownerPID) && isOnDisplay($0) }
        var texts: [String] = []
        var denied = false

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return SteamOCRRead(available: false, texts: [], permissionDenied: true)
        }

        let targetWindowIDs = Set(windows.map { CGWindowID($0.windowID) })
        let targets = content.windows.filter { targetWindowIDs.contains($0.windowID) }
        guard !targets.isEmpty else {
            return SteamOCRRead(available: false, texts: [], permissionDenied: false)
        }

        for window in targets {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width) * 2
            configuration.height = Int(window.frame.height) * 2
            configuration.showsCursor = false
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            } catch {
                denied = true
                continue
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continue
            }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if !texts.contains(text) {
                    texts.append(redact(text, maxLength: 200))
                }
                if texts.count >= 10 { break }
            }
            if texts.count >= 10 { break }
        }

        return SteamOCRRead(
            available: !texts.isEmpty,
            texts: texts,
            permissionDenied: denied
        )
    }

    // MARK: - Layer B: Steam's own generic logs

    /// Scan Steam's generic log directory (bounded tail) for error/warning
    /// lines. Account-specific/user-specific files are excluded. Results are
    /// deduped, bounded (≤ `limit`), and redacted.
    public static func scanSteamLogs(directory: URL?, limit: Int = 5) -> [ControlPlaneSteamLogEntry] {
        guard let directory else { return [] }
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }

        let genericComponents: [String: String] = [
            "bootstrap_log.txt": "bootstrap",
            "console_log.txt": "console",
            "cef_log.txt": "webhelper",
            "webhelper.txt": "webhelper",
            "webhelper_js.txt": "webhelper",
            "connection_log.txt": "connection",
            "service_log.txt": "service",
            "steamui.txt": "steamui",
            "steamui_html.txt": "steamui",
            "steamui_system.txt": "steamui",
            "steamui_update.txt": "steamui",
            "transport_steamui.txt": "transport",
            "systemmanager.txt": "system",
            "appinfo_log.txt": "content",
            "configstore_log.txt": "config",
            "shader_log.txt": "content",
        ]

        var entries: [ControlPlaneSteamLogEntry] = []
        for name in names {
            guard let component = genericComponents[name] else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                let text = String(data: data, encoding: .utf8) else { continue }
            let tail = String(text.suffix(65536))
            for line in tail.components(separatedBy: .newlines).reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let severity: String
                if hasWord(trimmed, ["FATAL", "fatal"]) {
                    severity = "error"
                } else if hasWord(trimmed, ["ERROR", "Error", "error", "FAIL", "Fail", "fail"]) {
                    severity = "error"
                } else if hasWord(trimmed, ["WARNING", "Warning", "warning", "WARN", "warn"]) {
                    severity = "warning"
                } else {
                    continue
                }
                let message = redact(trimmed, maxLength: 200)
                let entry = ControlPlaneSteamLogEntry(
                    source: "steam_log",
                    component: component,
                    severity: severity,
                    message: message
                )
                if !entries.contains(where: { $0.message == entry.message }) {
                    entries.append(entry)
                }
                if entries.count >= limit { return entries }
            }
            if entries.count >= limit { return entries }
        }
        return entries
    }

    // MARK: - Redaction

    /// Bound + redact a text fragment so a control-plane surface never carries
    /// absolute paths, CEF headers/PIDs, emails, or credential-like values.
    public static func redact(_ text: String, maxLength: Int) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip CEF-style headers: [tid:pid:yyMMdd/HHmmss.fff:LEVEL:...]
        result = result.replacingOccurrences(
            of: #"^\[\d+(?::\d+)*:[^\]]*\]\s*"#,
            with: "",
            options: .regularExpression
        )
        // Windows drive paths
        result = result.replacingOccurrences(
            of: #"[A-Za-z]:\\(?:[^\\\s]+\\)*[^\\\s]*"#,
            with: "<path>",
            options: .regularExpression
        )
        // POSIX paths
        result = result.replacingOccurrences(
            of: #"/[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\- ]*)*"#,
            with: "<path>",
            options: .regularExpression
        )
        // Emails
        result = result.replacingOccurrences(
            of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            with: "<email>",
            options: .regularExpression
        )
        // Credential-like assignments
        result = result.replacingOccurrences(
            of: #"(?i)\b(token|auth(?:orization)?|password|passwd|secret|credential)\b\s*=\s*\S+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        // Collapse whitespace
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(result.prefix(maxLength))
    }

    // MARK: - Word helpers

    public static func containsWord(_ haystack: String, _ keyword: String) -> Bool {
        let normalized = haystack.precomposedStringWithCanonicalMapping.lowercased()
        let key = keyword.precomposedStringWithCanonicalMapping.lowercased()
        guard !key.isEmpty else { return false }
        var searchStart = normalized.startIndex
        while let range = normalized.range(
            of: key,
            range: searchStart..<normalized.endIndex
        ) {
            let leftBoundary = range.lowerBound == normalized.startIndex
                || !isWordCharacter(normalized[normalized.index(before: range.lowerBound)])
            let rightBoundary = range.upperBound == normalized.endIndex
                || !isWordCharacter(normalized[range.upperBound])
            if leftBoundary && rightBoundary { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func hasWord(_ line: String, _ keywords: [String]) -> Bool {
        for keyword in keywords {
            if containsWord(line, keyword) { return true }
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
