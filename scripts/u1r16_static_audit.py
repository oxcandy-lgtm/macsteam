#!/usr/bin/env python3
"""U1R16 Static Audit Scanner — navigation authority + structural guards.

Usage:
  python3 scripts/u1r16_static_audit.py [--repo-root <root>]

Exit codes:
  0 = clean contract
  1 = semantic production mutation
  2 = infrastructure failure (missing/unreadable required file, missing
      required declaration or body, unbalanced body, scanner failure)

Required contracts (file presence + core declaration/body presence) are
checked FIRST; any absence is an infrastructure failure (exit 2), never a
clean result and never a semantic violation.
"""
import os
import re
import sys

VIEWS = os.path.join("Sources", "MacSteam", "Views")
ULTIMATE = os.path.join("Sources", "MacSteam", "Ultimate")
PREFIX = os.path.join("Sources", "MacSteam", "Prefix")

# Required files with the core declarations that must be present.
# Missing file or missing declaration → exit 2.
REQUIRED_CONTRACTS = [
    (VIEWS, "UltimateSetupView.swift",
     ["var presentation", "var pageTitle", "var progressIndicator",
      "var content", "diagnosticsPageView"]),
    (VIEWS, "PrefixSetupView.swift",
     ["func inspectPrefix", "static func production"]),
    (VIEWS, "UltimatePageResolver.swift",
     ["func presentation(", "func contentKind", "func steamMode",
      "func hasCanonicalNavigation"]),
    (VIEWS, "SteamSetupView.swift", []),
    (VIEWS, "RuntimeSetupView.swift", []),
    (VIEWS, "CloverPitLaunchView.swift", []),
    (ULTIMATE, "UltimateSetupCoordinator.swift",
     ["var canonicalPrefixEvidenceValid", "func canonicalURL",
      "func establishPrefixEvidence", "func establishExistingPrefixAcquisition",
      "func createPrefix", "func computePageCompletion"]),
    (PREFIX, "PrefixInspection.swift",
     ["PrefixInspecting", "PrefixAcquisitionSource"]),
]

# Required-body needles: missing or unbalanced body → exit 2.
REQUIRED_BODIES = [
    (VIEWS, "UltimateSetupView.swift",
     ["var presentation", "var pageTitle", "var progressIndicator",
      "var content", "diagnosticsPageView"]),
    (VIEWS, "PrefixSetupView.swift",
     ["func inspectPrefix", "static func production"]),
    (VIEWS, "UltimatePageResolver.swift",
     ["func presentation(", "func contentKind", "func steamMode",
      "func hasCanonicalNavigation"]),
    (ULTIMATE, "UltimateSetupCoordinator.swift",
     ["var canonicalPrefixEvidenceValid", "func canonicalURL",
      "func establishPrefixEvidence", "func establishExistingPrefixAcquisition",
      "func createPrefix", "func computePageCompletion"]),
]


def read_file(root: str, rel: str):
    path = os.path.join(root, rel)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        print(f"ERROR: cannot read required contract {path}: {e}", file=sys.stderr)
        sys.exit(2)


def infra(msg: str):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def required_body(content: str, needle: str, context: str):
    """Balanced-brace body following `needle`; missing/unparseable → exit 2."""
    idx = content.find(needle)
    if idx < 0:
        infra(f"required contract missing: {context} (no '{needle}')")
    brace = content.find("{", idx)
    if brace < 0:
        infra(f"required contract unparseable: {context} (no body brace for '{needle}')")
    depth = 1
    i = brace + 1
    while depth > 0 and i < len(content):
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        infra(f"required contract unparseable: {context} (unbalanced braces for '{needle}')")
    return content[brace + 1:i - 1]


def optional_body(content: str, needle: str):
    """Balanced-brace body following `needle`, or None when absent."""
    idx = content.find(needle)
    if idx < 0:
        return None
    brace = content.find("{", idx)
    if brace < 0:
        return None
    depth = 1
    i = brace + 1
    while depth > 0 and i < len(content):
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        return None
    return content[brace + 1:i - 1]


def clean_swift(src: str) -> str:
    """Replace comments and string/character literals with spaces.

    Newlines are preserved so statement boundaries survive. Tokens inside
    comments or literals never count as evidence.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            out.append(" ")
            out.append(" ")
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i + 1 < n:
                out.append(" ")
                out.append(" ")
                i += 2
        elif c == '"' or c == "'":
            quote = c
            out.append(" ")
            i += 1
            while i < n:
                if src[i] == "\\" and i + 1 < n:
                    out.append(" ")
                    out.append(" ")
                    i += 2
                    continue
                if src[i] == quote:
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def normalize_expr(expr: str) -> str:
    """Strip outer simple parens repeatedly, then collapse whitespace."""
    e = expr.strip()
    changed = True
    while changed and e:
        changed = False
        if e.startswith("(") and e.endswith(")"):
            depth = 0
            balanced = True
            for j, ch in enumerate(e):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0 and j != len(e) - 1:
                        balanced = False
                        break
            if balanced:
                e = e[1:-1].strip()
                changed = True
    return " ".join(e.split())


def balanced_parens(text: str, open_idx: int):
    """Return the inner text of the balanced parens starting at open_idx."""
    depth = 0
    j = open_idx
    n = len(text)
    while j < n:
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:j]
        j += 1
    return None


def split_args(inner: str) -> list:
    """Split call arguments on top-level commas."""
    args = []
    depth = 0
    cur = []
    for ch in inner:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            args.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        args.append("".join(cur))
    return args


def labeled_args(inner: str) -> dict:
    """Map argument labels to normalized values (e.g. for:/source:)."""
    out = {}
    for a in split_args(inner):
        m = re.match(r"\s*(\w+)\s*:\s*(.*)$", a, re.S)
        if m:
            out[m.group(1)] = normalize_expr(m.group(2))
    return out


def top_level_returns(cleaned_body: str):
    """Yield (index, normalized_expression) for returns at brace-depth 0.

    The expression continues across newlines only when the next
    non-whitespace token is a continuation operator, or when inside
    parentheses. Returns None markers are not included. An unbalanced
    parenthesis in an expression raises SystemExit(2).
    """
    returns = []
    depth = 0
    i = 0
    n = len(cleaned_body)
    while i < n:
        c = cleaned_body[i]
        if c == "{":
            depth += 1
            i += 1
            continue
        if c == "}":
            depth -= 1
            i += 1
            continue
        if depth == 0 and cleaned_body.startswith("return", i):
            if i > 0 and (cleaned_body[i - 1].isalnum() or cleaned_body[i - 1] == "_"):
                i += 1
                continue
            after = cleaned_body[i + 6:i + 7] if i + 6 < n else ""
            if after and (after.isalnum() or after == "_"):
                i += 1
                continue
            j = i + 6
            while j < n and cleaned_body[j] in " \t\r\n":
                j += 1
            expr_start = j
            pdepth = 0
            while j < n:
                ch = cleaned_body[j]
                if ch == "(":
                    pdepth += 1
                elif ch == ")":
                    pdepth -= 1
                if pdepth == 0 and ch == ";":
                    break
                if pdepth == 0 and ch == "\n":
                    k = j + 1
                    while k < n and cleaned_body[k] in " \t":
                        k += 1
                    nxt = cleaned_body[k] if k < n else ""
                    if nxt in "|&?=+*-/.,:!<>^%":
                        j = k
                        continue
                    break
                j += 1
            if pdepth != 0:
                infra(f"required contract unparseable: unbalanced parentheses "
                      f"in return expression at offset {i}")
            expr = cleaned_body[expr_start:j]
            returns.append((i, normalize_expr(expr)))
            i = j
            continue
        i += 1
    return returns


def extract_calls(cleaned_body: str, name: str):
    """Return list of labeled-arg dicts for every `name(` call."""
    calls = []
    for m in re.finditer(r"\b" + re.escape(name) + r"\s*\(", cleaned_body):
        inner = balanced_parens(cleaned_body, m.end() - 1)
        if inner is None:
            infra(f"required contract unparseable: unbalanced parens in {name} call")
        calls.append(labeled_args(inner))
    return calls


def iter_swift_files(root: str, rel_dir: str):
    base = os.path.join(root, rel_dir)
    if not os.path.isdir(base):
        return
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in filenames:
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


def guard(label: str):
    def deco(fn):
        GUARDS.append((label, fn))
        return fn
    return deco


GUARDS = []  # (label, fn(root) -> list[str])


@guard("coordinator.state write in Views")
def _(root: str) -> list[str]:
    out = []
    for path in iter_swift_files(root, VIEWS):
        content = read_file(root, os.path.relpath(path, root))
        if content is None:
            continue
        for lineno, line in enumerate(content.splitlines(), 1):
            if re.search(r"\bcoordinator\.state\s*=(?!=)", line):
                if not re.search(r"\bcoordinator\.state\s*==?\s*", line):
                    out.append(f"{path}:{lineno}")
    return out


@guard("coordinator.currentPage write in Views")
def _(root: str) -> list[str]:
    out = []
    for path in iter_swift_files(root, VIEWS):
        content = read_file(root, os.path.relpath(path, root))
        if content is None:
            continue
        for lineno, line in enumerate(content.splitlines(), 1):
            if re.search(r"\bcoordinator\.currentPage\s*=(?!=)", line):
                out.append(f"{path}:{lineno}")
    return out


@guard("root dispatch on coordinator.state in UltimateSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    return [
        f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: switch coordinator.state"
        for _ in re.finditer(r"switch\s+coordinator\.state", content)
    ]


@guard("presentation descriptor not consumed by root view")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    if "presentation" not in content:
        return [f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                "UltimatePageResolver.presentation not consumed"]
    if "UltimatePageResolver.presentation" not in content:
        return [f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                "presentation not derived from UltimatePageResolver.presentation"]
    return []


@guard("content must dispatch on presentation.contentKind")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    body = required_body(content, "var content", "UltimateSetupView.content")
    if "presentation.contentKind" not in body:
        return [f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                "content does not dispatch on presentation.contentKind"]
    return []


@guard("step indicator must derive from presentation.stepNumber")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    body = required_body(content, "var progressIndicator",
                         "UltimateSetupView.progressIndicator")
    if "presentation.stepNumber" not in body:
        return [f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                "step indicator does not derive from presentation.stepNumber"]
    return []


@guard("pageTitle must derive from presentation")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    body = required_body(content, "var pageTitle", "UltimateSetupView.pageTitle")
    if "presentation." not in body:
        return [f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                "pageTitle does not derive from presentation"]
    return []


@guard("Steam pages merged into one case in UltimateSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    return [
        f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: merged steam case"
        for _ in re.finditer(r"case\s+\.steamInstaller\s*,\s*\.steamClient", content)
    ]


@guard("steamMode resolver case mapping invalid")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimatePageResolver.swift"))
    if content is None:
        infra("required contract missing: UltimatePageResolver.swift")
    body = required_body(content, "func steamMode", "UltimatePageResolver.steamMode")
    out = []
    # Case/return ownership is analyzed per case: the DIRECT return of each
    # case must sit on the same line as the case pattern. Nested/unreachable
    # return tokens elsewhere do not satisfy the mapping.
    if not re.search(r"case\s+\.steamInstaller\s*:\s*return\s+\.installer", body):
        out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                   "steamInstaller case must directly return .installer")
    if not re.search(r"case\s+\.steamClient\s*:\s*return\s+\.client", body):
        out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                   "steamClient case must directly return .client")
    if not re.search(r"default\s*:\s*return\s+nil", body):
        out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                   "default case must directly return nil")
    return out


@guard("SteamSetupView direct recheckCloverPit (canonical lane violation)")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "SteamSetupView.swift"))
    if content is None:
        infra("required contract missing: SteamSetupView.swift")
    return [
        f"{os.path.join(VIEWS, 'SteamSetupView.swift')}: direct recheckCloverPit()"
        for _ in re.finditer(r"recheckCloverPit\s*\(", content)
    ]


@guard("navigation cleanup swallowed with try? in Views")
def _(root: str) -> list[str]:
    out = []
    for path in iter_swift_files(root, VIEWS):
        content = read_file(root, os.path.relpath(path, root))
        if content is None:
            continue
        for lineno, line in enumerate(content.splitlines(), 1):
            if re.search(r"try\?\s*await\s+coordinator\.", line):
                out.append(f"{path}:{lineno}")
    return out


@guard("@State inspection in PrefixSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "PrefixSetupView.swift"))
    if content is None:
        infra("required contract missing: PrefixSetupView.swift")
    return [
        f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: @State inspection"
        for _ in re.finditer(r"@State[^\n]*\binspection\b", content)
    ]


@guard("local PrefixInspector authority in PrefixSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "PrefixSetupView.swift"))
    if content is None:
        infra("required contract missing: PrefixSetupView.swift")
    return [
        f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: local PrefixInspector()"
        for _ in re.finditer(r"PrefixInspector\s*\(", content)
    ]


@guard("prefix Inspect button bypasses the production lane")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "PrefixSetupView.swift"))
    if content is None:
        infra("required contract missing: PrefixSetupView.swift")
    body = required_body(content, "func inspectPrefix", "PrefixSetupView.inspectPrefix")
    if "inspectAction.run" not in body:
        return [f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: "
                "Inspect button path does not invoke inspectAction.run()"]
    return []


@guard("PrefixInspectAction.production must call inspectCanonicalPrefix exactly once")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "PrefixSetupView.swift"))
    if content is None:
        infra("required contract missing: PrefixSetupView.swift")
    body = required_body(content, "static func production",
                         "PrefixInspectAction.production")
    count = body.count("inspectCanonicalPrefix")
    if count != 1:
        return [f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: "
                f"PrefixInspectAction.production calls inspectCanonicalPrefix "
                f"{count} times (must be exactly 1)"]
    return []


@guard("ForEach(logLines, id: \\.self) in Views (unstable log identity)")
def _(root: str) -> list[str]:
    out = []
    for path in iter_swift_files(root, VIEWS):
        content = read_file(root, os.path.relpath(path, root))
        if content is None:
            continue
        for lineno, line in enumerate(content.splitlines(), 1):
            if re.search(r"ForEach\s*\(\s*logLines\s*,\s*id:\s*\\?\.self\s*\)", line):
                out.append(f"{path}:{lineno}")
    return out


@guard("Diagnostics page missing canonical footer in UltimateSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    body = required_body(content, "diagnosticsPageView",
                         "UltimateSetupView.diagnosticsPageView")
    out = []
    if "InstallerNavigationFooter" not in body and "canonicalNavigationFooter" not in body:
        out.append(f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                   "diagnostics page lacks a canonical navigation footer in its own body")
    if re.search(r"coordinator\.(currentPage|state)\s*=", body):
        out.append(f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                   "diagnostics page mutates coordinator page/state directly")
    return out


@guard("footer must derive from presentation.footerPage")
def _(root: str) -> list[str]:
    out = []
    for path in iter_swift_files(root, VIEWS):
        content = read_file(root, os.path.relpath(path, root))
        if content is None:
            continue
        # Only files that USE the footer component (call syntax), not the
        # component's own declaration file.
        if "InstallerNavigationFooter(" not in content:
            continue
        if "presentation.footerPage" not in content:
            out.append(f"{path}: footer does not derive from presentation.footerPage")
        for lineno, line in enumerate(content.splitlines(), 1):
            if re.search(r"currentPage:\s*coordinator\.currentPage", line):
                out.append(f"{path}:{lineno}: footer uses coordinator.currentPage "
                           "instead of presentation.footerPage")
            if re.search(r"currentPage:\s*\.[a-zA-Z]", line):
                out.append(f"{path}:{lineno}: footer hardcodes a page literal")
    return out


@guard("surface ignores navigation capability")
def _(root: str) -> list[str]:
    """All six surfaces must gate their navigation on the presentation.

    Each surface's navigation body must either use the shared production
    helper `canonicalNavigationFooter(...)` or satisfy all three points:
    presentation.hasCanonicalNavigation + presentation.footerPage +
    coordinator.send(intent). Scoped per surface body — a single
    hasCanonicalNavigation anywhere in UltimateSetupView.swift does not
    satisfy the diagnostics surface. A bare InstallerNavigationFooter call
    inside a navigation body (rendering a footer without the shared helper)
    is also a violation.
    """
    surfaces = [
        ("RuntimeSetupView.swift", "var navigationButtons", "runtime"),
        ("PrefixSetupView.swift", "var navigationButtons", "environment"),
        ("SteamSetupView.swift", "var navigationButtons", "steam"),
        ("CloverPitLaunchView.swift", "var navigationButtons", "cloverPit"),
        ("UltimateSetupView.swift", "var diagnosticsPageView", "diagnostics"),
    ]
    out = []
    for fname, body_needle, surface in surfaces:
        content = read_file(root, os.path.join(VIEWS, fname))
        if content is None:
            infra(f"required contract missing: {fname}")
        cleaned = clean_swift(content)
        body = optional_body(cleaned, body_needle)
        if body is None:
            out.append(f"{os.path.join(VIEWS, fname)}: {surface} surface has "
                       "no navigation body consuming the capability")
            continue
        uses_helper = "canonicalNavigationFooter(" in body
        three_points = all(t in body for t in (
            "presentation.hasCanonicalNavigation",
            "presentation.footerPage",
            "coordinator.send",
        ))
        if not uses_helper and not three_points:
            out.append(f"{os.path.join(VIEWS, fname)}: {surface} surface "
                       "ignores the navigation capability")
        if "InstallerNavigationFooter(" in body:
            out.append(f"{os.path.join(VIEWS, fname)}: {surface} surface renders "
                       "a footer bypassing the shared helper")
    return out


@guard("surface canonical footer argument mismatch")
def _(root: str) -> list[str]:
    """Each surface's navigation body must call the shared helper with the
    LOCAL presentation and LOCAL coordinator — same call, exact arguments
    (whitespace/line-break/argument-order variants allowed). A hardcoded
    page presentation, another presentation, another coordinator, or
    `self.coordinator` all fail.
    """
    surfaces = [
        ("RuntimeSetupView.swift", "var navigationButtons", "runtime"),
        ("PrefixSetupView.swift", "var navigationButtons", "environment"),
        ("SteamSetupView.swift", "var navigationButtons", "steam"),
        ("CloverPitLaunchView.swift", "var navigationButtons", "cloverPit"),
        ("UltimateSetupView.swift", "var diagnosticsPageView", "diagnostics"),
    ]
    out = []
    for fname, body_needle, surface in surfaces:
        content = read_file(root, os.path.join(VIEWS, fname))
        if content is None:
            infra(f"required contract missing: {fname}")
        cleaned = clean_swift(content)
        body = optional_body(cleaned, body_needle)
        if body is None:
            continue
        for call in extract_calls(body, "canonicalNavigationFooter"):
            p = call.get("presentation")
            c = call.get("coordinator")
            if p != "presentation" or c != "coordinator":
                out.append(f"{os.path.join(VIEWS, fname)}: {surface} surface "
                           f"canonicalNavigationFooter arguments "
                           f"(presentation: {p}, coordinator: {c}) must be "
                           "(presentation: presentation, coordinator: coordinator)")
    return out


@guard("shared footer helper ignores navigation capability")
def _(root: str) -> list[str]:
    out = []
    for path in iter_swift_files(root, VIEWS):
        content = read_file(root, os.path.relpath(path, root))
        if content is None:
            continue
        if "func canonicalNavigationFooter" not in content:
            continue
        body = required_body(content, "func canonicalNavigationFooter",
                             "canonicalNavigationFooter helper")
        missing = [t for t in (
            "hasCanonicalNavigation", "presentation.footerPage",
            "coordinator.send", "InstallerNavigationFooter") if t not in body]
        if missing:
            out.append(f"{path}: shared footer helper missing {missing}")
    return out


@guard("canonicalPrefixEvidenceValid semantics incomplete")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    body = required_body(content, "var canonicalPrefixEvidenceValid",
                         "UltimateSetupCoordinator.canonicalPrefixEvidenceValid")
    norm = " ".join(body.split())
    out = []
    required_tokens = [
        ("let layout = prefixLayout", "layout binding"),
        ("let inspection = prefixInspection", "inspection binding"),
        ("inspection.isValid", "inspection.isValid check"),
        ("return false", "failure return false"),
    ]
    for token, what in required_tokens:
        if token not in norm:
            out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                       f"canonicalPrefixEvidenceValid missing {what}")
    return out


@guard("canonicalPrefixEvidenceValid terminal return mismatch")
def _(root: str) -> list[str]:
    """The top-level success return must be EXACTLY
    `canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)`
    after whitespace/outer-paren normalization — exactly one, top-level
    only. Trailing `|| true`, leading `true &&`, unused-correct-expression
    + `return true`, ternary wrapping, and any other shape are violations.
    """
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    body = required_body(content, "var canonicalPrefixEvidenceValid",
                         "UltimateSetupCoordinator.canonicalPrefixEvidenceValid")
    cleaned = clean_swift(body)
    returns = top_level_returns(cleaned)
    expected = "canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)"
    matching = [expr for _, expr in returns if expr == expected]
    out = []
    if not returns:
        # A single-expression body is an implicit return.
        if normalize_expr(cleaned) != expected:
            out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                       "no explicit top-level success return found")
    elif len(matching) != 1:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   f"top-level success return must be exactly '{expected}' "
                   f"(found {len(matching)} of {len(returns)} returns)")
    return out


@guard("canonicalURL terminal return mismatch")
def _(root: str) -> list[str]:
    """canonicalURL(_:) top-level return must be EXACTLY
    `url.standardizedFileURL.resolvingSymlinksInPath()` — the canonical
    expression must be the returned value, not a discarded side effect.
    """
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    body = required_body(content, "func canonicalURL",
                         "UltimateSetupCoordinator.canonicalURL")
    cleaned = clean_swift(body)
    returns = top_level_returns(cleaned)
    expected = "url.standardizedFileURL.resolvingSymlinksInPath()"
    matching = [expr for _, expr in returns if expr == expected]
    out = []
    if not returns:
        # A single-expression body is an implicit return.
        if normalize_expr(cleaned) != expected:
            out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                       "no explicit top-level return found in canonicalURL")
    elif len(matching) != 1:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   f"canonicalURL top-level return must be exactly '{expected}' "
                   f"(found {len(matching)} of {len(returns)} returns)")
    return out


@guard("prefix acquisition branch evidence ordering violation")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    out = []
    cleaned = clean_swift(content)
    if "func establishExistingPrefixAcquisition" not in cleaned:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "production acquisition router missing")
    else:
        router_body = required_body(
            cleaned, "func establishExistingPrefixAcquisition",
            "UltimateSetupCoordinator.establishExistingPrefixAcquisition"
        )
        # Branch-local same-call analysis: the concrete evidence call before
        # the branch return must bind BOTH the selected layout and its
        # matching source in the SAME call. Comment/string tokens, unrelated
        # calls, and other branches never satisfy a branch.
        for m in re.finditer(
            r"if\s+let\s+(\w+)\s*=\s*(validatedLayout|adoptedLayout)", router_body):
            branch_var = m.group(1)
            source_kind = m.group(2)
            expected_source = ".existingCanonical" if source_kind == "validatedLayout" \
                else ".adoptedSteam"
            rest = router_body[m.end():]
            return_pos = rest.find("return")
            branch_slice = rest[:return_pos] if return_pos >= 0 else rest
            calls = extract_calls(branch_slice, "establishPrefixEvidence")
            matching = [c for c in calls
                        if c.get("for") == branch_var and c.get("source") == expected_source]
            if not calls:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} never establishes evidence "
                           "before its return")
            elif len(matching) != 1:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} must have exactly one "
                           f"establishPrefixEvidence(for: {branch_var}, "
                           f"source: {expected_source}) before its return "
                           f"(found {len(matching)} matching of {len(calls)} calls)")
            for c in calls:
                if c.get("for") == branch_var and c.get("source") != expected_source:
                    out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                               f"router branch {branch_var} evidence call binds source "
                               f"'{c.get('source')}' (expected {expected_source})")
            if return_pos < 0:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} has no return statement")
    # Newly-initialized path: the concrete same-call evidence
    # `establishPrefixEvidence(for: layout, source: .newlyInitialized)` must
    # precede the `.prefixReady` state transition.
    create_body = required_body(cleaned, "func createPrefix",
                                "UltimateSetupCoordinator.createPrefix")
    pos_ready2 = create_body.find("state = .prefixReady")
    slice_end = pos_ready2 if pos_ready2 >= 0 else len(create_body)
    new_calls = extract_calls(create_body[:slice_end], "establishPrefixEvidence")
    new_matching = [c for c in new_calls
                    if c.get("for") == "layout" and c.get("source") == ".newlyInitialized"]
    if len(new_matching) != 1:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "newlyInitialized path must have exactly one "
                   "establishPrefixEvidence(for: layout, source: .newlyInitialized) "
                   "before state = .prefixReady "
                   f"(found {len(new_matching)} matching of {len(new_calls)} calls)")
    return out


@guard("environment completion not bound to canonicalPrefixEvidenceValid")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    m = re.search(r"completion\[\.environment\]\s*=\s*([^\n]+)", content)
    if not m:
        return [f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                "environment completion assignment missing"]
    rhs = m.group(1)
    if "canonicalPrefixEvidenceValid" not in rhs:
        return [f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                f"environment assignment does not bind canonicalPrefixEvidenceValid "
                f"(got: {rhs.strip()})"]
    return []


def scan(root: str) -> list[str]:
    # 0) Required contracts — absence is an infrastructure failure (exit 2).
    for rel_dir, fname, tokens in REQUIRED_CONTRACTS:
        rel = os.path.join(rel_dir, fname)
        content = read_file(root, rel)
        if content is None:
            infra(f"required contract missing: {rel}")
        for tok in tokens:
            if tok not in content:
                infra(f"required contract missing: {rel} (no '{tok}')")
    # 1) Required bodies — missing or unbalanced body is exit 2.
    for rel_dir, fname, needles in REQUIRED_BODIES:
        rel = os.path.join(rel_dir, fname)
        content = read_file(root, rel)
        if content is None:
            infra(f"required contract missing: {rel}")
        for needle in needles:
            required_body(content, needle, rel)

    violations: list[str] = []
    for label, fn in GUARDS:
        try:
            found = fn(root)
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001 — fail-closed on scanner error
            print(f"ERROR: scanner failure in '{label}': {e}", file=sys.stderr)
            sys.exit(2)
        for item in found:
            violations.append(f"{label}: {item}")
    return violations


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="U1R16 navigation authority + structural guard scanner"
    )
    parser.add_argument("--repo-root", default=None,
                        help="Repository root (default: parent of scripts dir)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.normpath(os.path.join(script_dir, ".."))
    root = args.repo_root or project_root

    if not os.path.isdir(root):
        print(f"ERROR: directory not found: {root}", file=sys.stderr)
        sys.exit(2)

    violations = scan(root)
    if violations:
        for v in violations:
            print(f"VIOLATION: {v}")
        sys.exit(1)
    else:
        print("STATIC SCANNER PASSED — 0 navigation authority violations")
        sys.exit(0)


if __name__ == "__main__":
    main()
