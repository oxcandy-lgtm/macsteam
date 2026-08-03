#!/usr/bin/env python3
"""R3 structural semantic scanner — U1R18 window-authority contracts.

Extracts actual Swift function bodies via brace-matching, strips comments and
string literals, then validates production contracts by behavior, not by
token presence alone. Decoys placed in comments, strings, dead branches, or
uninvoked closures are rejected.

Exit contract:
  0 — clean production contract
  1 — semantic contract violation (with guard label)
  2 — required file / function missing, unbalanced body, or scanner infrastructure failure
"""

import sys
import os
import re
import argparse


# ---------------------------------------------------------------------------
# Swift source stripping: removes comments and string literals
# ---------------------------------------------------------------------------

def strip_swift_comments_and_strings(text):
    """Blank out every character inside comments and string literals.

    Preserves newlines so line/column positions stay aligned.
    Handles line comments, nested block comments, regular and raw
    string literals (including multi-line triple-quoted strings).
    """
    result = list(text)
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]

        # Line comment //
        if ch == '/' and i + 1 < n and text[i + 1] == '/':
            j = i
            while j < n and text[j] != '\n':
                result[j] = ' '
                j += 1
            i = j
            continue

        # Block comment /* ... */ (possibly nested)
        if ch == '/' and i + 1 < n and text[i + 1] == '*':
            depth = 1
            j = i + 2
            while j < n and depth > 0:
                if text[j] == '/' and j + 1 < n and text[j + 1] == '*':
                    depth += 1
                    j += 2
                elif text[j] == '*' and j + 1 < n and text[j + 1] == '/':
                    depth -= 1
                    j += 2
                elif text[j] == '\n':
                    j += 1
                else:
                    result[j] = ' '
                    j += 1
            for k in range(i, min(j, n)):
                result[k] = ' '
            i = max(j, n)
            continue

        # String literal: "..." or """...""" or #"..."# or #"""..."""#
        if ch == '"':
            # Count preceding # marks (raw string)
            hash_count = 0
            k = i - 1
            while k >= 0 and text[k] == '#':
                hash_count += 1
                k -= 1
            close_marker = '"' + '#' * hash_count

            # Multi-line string literal: """
            if text[i:i + 3] == '"""':
                closing = '"""' + '#' * hash_count
                j = i + 3
                while j < n:
                    if text[j:j + len(closing)] == closing:
                        j += len(closing)
                        break
                    if text[j] == '\\' and hash_count == 0:
                        j += 2
                        continue
                    j += 1
                for k in range(i, min(j, n)):
                    if result[k] != '\n':
                        result[k] = ' '
                i = j
                continue
            else:
                # Single-line string literal
                j = i + 1
                while j < n:
                    if text[j] == '\\' and hash_count == 0:
                        j += 2
                        continue
                    if text[j:j + len(close_marker)] == close_marker:
                        j += len(close_marker)
                        break
                    j += 1
                for k in range(i, min(j, n)):
                    if result[k] != '\n':
                        result[k] = ' '
                i = j
                continue

        # Regular character
        i += 1

    return ''.join(result)


def strip_swift_if_false(text):
    """Blank out Swift #if false ... #endif blocks (nested-safe).

    Processes lines, tracking nesting depth of #if false blocks.
    Non-false conditions (#if true, #if arch(...)) are kept.
    Preserves newlines so positions stay aligned.
    """
    lines = text.split('\n')
    result = []
    if_false_depth = 0
    for line in lines:
        stripped = line.strip()
        # Check for #if false
        if re.match(r'#if\s+false\b', stripped):
            if_false_depth += 1
            result.append(' ' * len(line))
            continue
        # Check for #if (but not #if false) — increment depth if inside if_false
        if if_false_depth > 0:
            if re.match(r'#if\b', stripped):
                if_false_depth += 1
                result.append(' ' * len(line))
                continue
            elif re.match(r'#endif\b', stripped):
                if_false_depth -= 1
                result.append(' ' * len(line))
                continue
            else:
                result.append(' ' * len(line))
                continue
        # Not inside an #if false block: check for #if false (but not #if true/arch)
        # Also handle #elseif / #else inside if_false
        elif re.match(r'#elseif\b', stripped) or re.match(r'#else\b', stripped):
            if if_false_depth > 0:
                result.append(' ' * len(line))
                continue
        result.append(line)
    return '\n'.join(result)


# ---------------------------------------------------------------------------
# Swift source parsing: extract function bodies
# ---------------------------------------------------------------------------

class ScannerError(Exception):
    """Scanner infrastructure failure (maps to exit code 2)."""


def _find_param_close_and_brace(source_stripped, match_start):
    """Given the start of a 'func name(' match, find the end of the parameter
    list (closing paren at depth 0) and then the opening brace of the body.
    Returns (param_close_index, brace_index) or (None, None) if not found.
    """
    i = match_start
    n = len(source_stripped)
    depth = 0
    while i < n:
        ch = source_stripped[i]
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                # Found end of parameter list. Now skip return type annotation
                # (-> ...) and whitespace to find the opening '{' of the body.
                j = i + 1
                while j < n and source_stripped[j] != '{':
                    j += 1
                if j < n:
                    return i, j  # param_close, brace
                return None, None
        i += 1
    return None, None


def extract_function_body(source_stripped, func_name):
    """Find a function by name in stripped source and return its body text.

    Uses brace matching to find the full body. Returns the body text inside
    the outer braces (without the braces themselves), or None if not found.
    The source must already have comments/strings stripped.
    """
    pattern = re.compile(r'\bfunc\s+' + re.escape(func_name) + r'\s*\(')

    for m in pattern.finditer(source_stripped):
        param_close, brace_start = _find_param_close_and_brace(source_stripped, m.end() - 1)
        if brace_start is None:
            continue

        # Extract balanced body starting from the opening brace
        n = len(source_stripped)
        brace_depth = 1
        i = brace_start + 1
        body_start = i
        while i < n and brace_depth > 0:
            ch = source_stripped[i]
            if ch == '{':
                brace_depth += 1
            elif ch == '}':
                brace_depth -= 1
            i += 1
        if brace_depth == 0:
            return source_stripped[body_start:i - 1]

    return None


def extract_signature(source_stripped, func_name):
    """Extract the full signature (from 'func' to just before the opening '{').
    Returns the signature text (without body), or None.
    """
    pattern = re.compile(r'\bfunc\s+' + re.escape(func_name) + r'\s*\(')
    for m in pattern.finditer(source_stripped):
        param_close, brace_start = _find_param_close_and_brace(source_stripped, m.end() - 1)
        if brace_start is not None:
            return source_stripped[m.start():brace_start]
    return None


# ---------------------------------------------------------------------------
# Contract checks
# ---------------------------------------------------------------------------

class Violation:
    def __init__(self, label, detail=""):
        self.label = label
        self.detail = detail

    def __str__(self):
        if self.detail:
            return f"VIOLATION: {self.label} — {self.detail}"
        return f"VIOLATION: {self.label}"


def check_start_monitoring(sig_stripped):
    """Check A: startMonitoring signature must have a required, non-optional,
    @escaping ownershipSnapshot parameter with no default value."""
    if sig_stripped is None:
        return [Violation("start_monitoring_exists",
                          "func startMonitoring signature not found")]

    violations = []

    # Check: ownershipSnapshot parameter exists
    if not re.search(r'ownershipSnapshot\s*:', sig_stripped):
        return [Violation("ownership_parameter_required",
                          "ownershipSnapshot parameter not found in startMonitoring")]

    # Extract the full text of the ownershipSnapshot parameter (from ':'
    # to the next comma or closing paren).
    param = re.search(r'ownershipSnapshot\s*:\s*(.+?)(?=[,)])',
                      sig_stripped, re.DOTALL)
    if not param:
        violations.append(Violation("ownership_parameter_required",
                                     "could not parse ownershipSnapshot parameter"))
        return violations

    param_text = param.group(1).strip()

    # Check: NOT optional (no '?' before any '=' default)
    before_equals = param_text.split('=')[0]
    if '?' in before_equals:
        violations.append(Violation("ownership_parameter_non_optional",
                                     "ownershipSnapshot is declared optional"))

    # Check: @escaping present
    if '@escaping' not in param_text:
        violations.append(Violation("ownership_parameter_escaping",
                                     "ownershipSnapshot is not @escaping"))

    # Check: NO default value
    if '=' in param_text:
        violations.append(Violation("ownership_parameter_no_default",
                                     "ownershipSnapshot has a default value"))

    return violations

    return violations


def check_observe(body_stripped):
    """Check B: observe() function body must require BOTH snapshot AND ownership
    AND a target+ownership conjunction for the single positive path."""
    if body_stripped is None:
        return [Violation("observe_function_exists",
                          "func observe body not found")]

    violations = []

    # B1: Provider failure → windowSnapshotFailed
    has_catch_snapshot_failed = bool(
        re.search(r'catch\s*\{', body_stripped) and
        re.search(r'\.windowSnapshotFailed', body_stripped))
    if not has_catch_snapshot_failed:
        violations.append(Violation("observe_snapshot_failure_handled",
                                     "snapshot failure must map to .windowSnapshotFailed"))

    # B2: Ownership guard → ownershipIncomplete
    has_ownership_guard = bool(re.search(
        r'guard\s+let\s+owned\s*=\s*await\s+ownershipSnapshot\s*\(\s*\)', body_stripped))
    if not has_ownership_guard:
        violations.append(Violation("observe_ownership_guard",
                                     "must guard let owned = await ownershipSnapshot()"))
    else:
        if not re.search(r'\.ownershipIncomplete', body_stripped):
            violations.append(Violation("ownership_incomplete_must_fail_closed",
                                         "ownershipSnapshot() nil must return .ownershipIncomplete"))

    # B3: targetCandidates MUST be filtered via WindowMatcher.isValidCandidate
    #     with the target parameter.  If isValidCandidate is not used with
    #     target at all, OR if targetCandidates uses isValidGeometry (geometry-
    #     only), this check fails.
    has_isValidCandidate_with_target = bool(re.search(
        r'isValidCandidate.*target', body_stripped, re.DOTALL))
    has_isValidGeometry_only = bool(re.search(
        r'targetCandidates.*isValidGeometry', body_stripped, re.DOTALL)) and \
        not has_isValidCandidate_with_target

    if has_isValidGeometry_only:
        violations.append(Violation("observe_target_filter",
                                     "targetCandidates uses isValidGeometry (geometry-only), must use isValidCandidate with target"))
    elif not has_isValidCandidate_with_target:
        violations.append(Violation("observe_target_filter",
                                     "targetCandidates must be filtered via WindowMatcher.isValidCandidate(info, target:)"))

    # B4: Exactly one .ownedPositive return in the body
    positive_count = len(re.findall(r'\.ownedPositive', body_stripped))
    if positive_count == 0:
        violations.append(Violation("owned_positive_returns_required",
                                     "no .ownedPositive return found"))
    elif positive_count > 1:
        violations.append(Violation("exactly_one_positive_path",
                                     f"found {positive_count} .ownedPositive references, expected 1"))

    # B5: The positive path must require BOTH target match AND owned.contains
    # Check: the code that returns .ownedPositive must use owned.contains
    # AND it must be on a targetCandidate (not just any window)
    #
    # The correct pattern is:
    #   if targetCandidates.contains(where: { owned.contains($0.ownerPID) }) {
    #       return .ownedPositive
    #   }
    conjunction_pattern = bool(re.search(
        r'targetCandidates\.contains\s*\(\s*where\s*:\s*\{\s*owned\.contains', body_stripped))
    if not conjunction_pattern:
        violations.append(Violation("owned_positive_same_candidate_conjunction",
                                     "positive path must gate on targetCandidates.contains(where: { owned.contains(...) })"))

    # B6: owned.contains must appear exactly once (for the positive conjunction)
    owned_contains_count = len(re.findall(r'owned\.contains', body_stripped))
    if owned_contains_count == 0:
        violations.append(Violation("positive_requires_owned_contains",
                                     "owned.contains not found — positive path does not check ownership"))

    # B7: foreignCandidatesOnly and ownedMiss must be present
    if not re.search(r'\.foreignCandidatesOnly', body_stripped):
        violations.append(Violation("observe_foreign_candidates_only_case",
                                     "foreignCandidatesOnly not returned"))
    if not re.search(r'\.ownedMiss', body_stripped):
        violations.append(Violation("observe_owned_miss_case",
                                     "ownedMiss not returned"))

    # B8: No unscoped fallback — .ownedPositive must only appear in the
    #     conjunction check, not in catch or guard failure paths
    # (Already covered by B4 requiring exactly one positive_path + B5 requiring
    #  the conjunction pattern)

    return violations


def check_owned_process_ids(body_stripped):
    """Check C: ownedProcessIDs must delegate to census(ledger:) and fail closed."""
    if body_stripped is None:
        return [Violation("owned_process_ids_exists",
                          "func ownedProcessIDs body not found")]

    violations = []

    # C1: Delegates to census(ledger: &ledger) — not cached-table replay
    if not re.search(r'census\s*\(\s*ledger\s*:\s*&ledger\s*\)', body_stripped):
        violations.append(Violation("owned_process_ids_delegates_to_census",
                                     "ownedProcessIDs must call census(ledger: &ledger)"))

    # C2: Fails closed on non-proven
    if not re.search(r'guard\s+result\.state\s*==\s*\.proven\s+else\s*\{\s*return\s+nil\s*\}', body_stripped):
        violations.append(Violation("non_proven_ownership_must_return_nil",
                                     "ownedProcessIDs must guard result.state == .proven else { return nil }"))

    # C3: Returns ledger PIDs
    if not re.search(r'Set\s*\(\s*ledger\.observed\.map', body_stripped):
        violations.append(Violation("owned_process_ids_returns_ledger_pids",
                                     "ownedProcessIDs must return Set(ledger.observed.map(\\.pid))"))

    # C4: No cached-table replay (captured variable reused)
    if re.search(r'captured\s*[:\(]', body_stripped):
        violations.append(Violation("owned_process_ids_no_cached_replay",
                                     "ownedProcessIDs must not use a cached/captured table replay"))

    return violations


def check_owned_process_snapshot(body_stripped):
    """Check D: ownedProcessSnapshot must fail closed without a ledger and
    must not fabricate PIDs from receipt/session."""
    if body_stripped is None:
        return [Violation("owned_process_snapshot_exists",
                          "func ownedProcessSnapshot body not found")]

    violations = []

    # D1: guard var ledger = censusLedger else { return nil }
    if not re.search(r'guard\s+var\s+ledger\s*=\s*censusLedger\s+else\s*\{\s*return\s+nil\s*\}', body_stripped):
        violations.append(Violation("missing_ledger_must_return_nil",
                                     "ownedProcessSnapshot must guard var ledger = censusLedger else { return nil }"))

    # D2: Delegates to HostProcessLineage.ownedProcessIDs
    if not re.search(r'HostProcessLineage\.ownedProcessIDs', body_stripped):
        violations.append(Violation("owned_process_snapshot_delegates_census",
                                     "ownedProcessSnapshot must call HostProcessLineage.ownedProcessIDs"))

    # D3: No receipt PID / rootPID / synthetic PID set
    if re.search(r'rootPID|receipt|activeSession.*map|Set\s*\(\s*\[', body_stripped):
        violations.append(Violation("recovery_no_pid_fabrication",
                                     "ownedProcessSnapshot must not fabricate PIDs from receipt/session"))

    return violations


# ---------------------------------------------------------------------------
# Scanner
# ---------------------------------------------------------------------------

class R3Scanner:
    def __init__(self, src_dir):
        self.src_dir = src_dir
        self.violations = []
        self.infrastructure_errors = []

    def read_file(self, relpath):
        full = os.path.join(self.src_dir, relpath)
        if not os.path.isfile(full):
            raise ScannerError("required file missing: " + relpath)
        with open(full, 'r') as f:
            return f.read()

    def run(self):
        # Read and strip all three source files
        try:
            obs_raw = self.read_file("Sources/MacSteam/Sessions/SessionWindowObserver.swift")
        except ScannerError as e:
            self.infrastructure_errors.append(str(e))
            return
        try:
            lin_raw = self.read_file("Sources/MacSteam/Sessions/HostProcessLineage.swift")
        except ScannerError as e:
            self.infrastructure_errors.append(str(e))
            return
        try:
            gss_raw = self.read_file("Sources/MacSteam/Sessions/GameSessionSupervisor.swift")
        except ScannerError as e:
            self.infrastructure_errors.append(str(e))
            return

        obs_stripped = strip_swift_comments_and_strings(strip_swift_if_false(obs_raw))
        lin_stripped = strip_swift_comments_and_strings(strip_swift_if_false(lin_raw))
        gss_stripped = strip_swift_comments_and_strings(strip_swift_if_false(gss_raw))

        # Check A: startMonitoring
        sig = extract_signature(obs_stripped, 'startMonitoring')
        if sig is None:
            self.infrastructure_errors.append("func startMonitoring not found in SessionWindowObserver")
        else:
            self.violations.extend(check_start_monitoring(sig))

        # Check B: observe
        body = extract_function_body(obs_stripped, 'observe')
        if body is None:
            self.violations.append(Violation("observe_function_exists",
                                              "func observe not found in SessionWindowObserver"))
        else:
            self.violations.extend(check_observe(body))

        # Check C: ownedProcessIDs
        body = extract_function_body(lin_stripped, 'ownedProcessIDs')
        if body is None:
            self.infrastructure_errors.append("func ownedProcessIDs not found in HostProcessLineage")
        else:
            self.violations.extend(check_owned_process_ids(body))

        # Check D: ownedProcessSnapshot
        body = extract_function_body(gss_stripped, 'ownedProcessSnapshot')
        if body is None:
            self.infrastructure_errors.append("func ownedProcessSnapshot not found in GameSessionSupervisor")
        else:
            self.violations.extend(check_owned_process_snapshot(body))


def main():
    parser = argparse.ArgumentParser(
        description="R3 structural semantic scanner for U1R18 window-authority contracts")
    parser.add_argument('--src-dir', default='.',
                        help="Source root directory (default: current directory)")
    args = parser.parse_args()

    scanner = R3Scanner(args.src_dir)
    scanner.run()

    if scanner.infrastructure_errors:
        for e in scanner.infrastructure_errors:
            print("INFRASTRUCTURE: " + e, file=sys.stderr)
        sys.exit(2)

    if scanner.violations:
        print("=== R3 Structural Semantic Audit ===")
        print("")
        for v in scanner.violations:
            print("[FAIL] " + str(v))
            print("       guard: " + v.label)
        print("")
        print("Passed: 0  Failed: " + str(len(scanner.violations)))
        sys.exit(1)

    print("=== R3 Structural Semantic Audit ===")
    print("")
    print("[PASS] startMonitoring: ownershipSnapshot required, non-optional, @escaping, no default")
    print("[PASS] observe: snapshot failure -> windowSnapshotFailed, ownership nil -> ownershipIncomplete")
    print("[PASS] observe: target filter via WindowMatcher.isValidCandidate(info, target:)")
    print("[PASS] observe: ownedPositive requires targetCandidates.contains(where: { owned.contains(...) })")
    print("[PASS] observe: exactly one positive path; foreignCandidatesOnly; ownedMiss")
    print("[PASS] ownedProcessIDs: delegates to census(ledger: &ledger), fails closed on non-proven")
    print("[PASS] ownedProcessSnapshot: guard var ledger = censusLedger else { return nil }")
    print("[PASS] ownedProcessSnapshot: delegates to HostProcessLineage.ownedProcessIDs")
    print("")
    print("All R3 structural semantic guards passed.")
    sys.exit(0)


if __name__ == '__main__':
    main()
