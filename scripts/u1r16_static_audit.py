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
    satisfy the diagnostics surface.
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
        body = optional_body(content, body_needle)
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
    success_return = "return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)"
    if success_return not in norm:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "success return is not exactly "
                   "canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)")
    elif norm.count(success_return) != 1:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   f"{norm.count(success_return)} success returns (must be exactly 1)")
    # canonicalURL(_:) must apply both canonicalizations to the input URL.
    cu_body = required_body(content, "func canonicalURL",
                            "UltimateSetupCoordinator.canonicalURL")
    cu_norm = " ".join(cu_body.split())
    if "url.standardizedFileURL.resolvingSymlinksInPath()" not in cu_norm:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "canonicalURL must return url.standardizedFileURL."
                   "resolvingSymlinksInPath()")
    return out


@guard("prefix acquisition branch evidence ordering violation")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    out = []
    if "func establishExistingPrefixAcquisition" not in content:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "production acquisition router missing")
    else:
        router_body = required_body(
            content, "func establishExistingPrefixAcquisition",
            "UltimateSetupCoordinator.establishExistingPrefixAcquisition"
        )
        # Branch-local analysis: each branch's evidence call must use the
        # SELECTED variable with its MATCHING source, BEFORE the branch return.
        # Tokens from other branches or comments never satisfy a branch.
        for m in re.finditer(
            r"if\s+let\s+(\w+)\s*=\s*(validatedLayout|adoptedLayout)", router_body):
            branch_var = m.group(1)
            source_kind = m.group(2)
            expected_source = ".existingCanonical" if source_kind == "validatedLayout" \
                else ".adoptedSteam"
            rest = router_body[m.end():]
            return_pos = rest.find("return")
            branch_head = rest[:return_pos] if return_pos >= 0 else rest
            em = re.search(r"establishPrefixEvidence\(\s*for:\s*([^,\s]+)", branch_head)
            if not em:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} never establishes evidence")
                continue
            if em.group(1) != branch_var:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} passes layout "
                           f"'{em.group(1)}' instead of the selected layout")
            if f"source: {expected_source}" not in branch_head:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} lacks source "
                           f"{expected_source} before its return")
            if return_pos >= 0 and em.start() > return_pos:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"router branch {branch_var} establishes evidence "
                           "after its return")
    # Newly-initialized path: evidence for the ACTUAL new layout before
    # the prefixReady state change.
    body = required_body(content, "func createPrefix",
                         "UltimateSetupCoordinator.createPrefix")
    new_call = re.search(
        r"establishPrefixEvidence\(\s*for:\s*layout\s*,\s*source:\s*\.newlyInitialized",
        body)
    if not new_call:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "newlyInitialized path lacks establishPrefixEvidence(for: layout, "
                   "source: .newlyInitialized)")
    pos_ready2 = body.find("state = .prefixReady")
    if new_call and pos_ready2 >= 0 and new_call.start() > pos_ready2:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "newlyInitialized evidence established after prefixReady")
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
