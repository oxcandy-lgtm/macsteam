#!/usr/bin/env python3
"""U1R16 Static Audit Scanner — navigation authority + structural guards.

Usage:
  python3 scripts/u1r16_static_audit.py [--repo-root <root>]

Exit codes:
  0 = clean contract
  1 = production mutation violation
  2 = infrastructure failure (missing/unreadable required contract,
      missing required function, unparseable required body)

Required contracts (file presence + core declaration presence) are checked
FIRST; their absence is an infrastructure failure, never a clean result.
"""
import os
import re
import sys

VIEWS = os.path.join("Sources", "MacSteam", "Views")
ULTIMATE = os.path.join("Sources", "MacSteam", "Ultimate")
PREFIX = os.path.join("Sources", "MacSteam", "Prefix")

# Required files with the core declarations that must be present.
REQUIRED_CONTRACTS = [
    (VIEWS, "UltimateSetupView.swift", ["diagnosticsPageView"]),
    (VIEWS, "PrefixSetupView.swift", ["inspectPrefix", "PrefixInspectAction"]),
    (VIEWS, "UltimatePageResolver.swift",
     ["func presentation(", "func steamMode", "func contentKind"]),
    (VIEWS, "SteamSetupView.swift", ["InstallerNavigationFooter"]),
    (ULTIMATE, "UltimateSetupCoordinator.swift",
     ["func computePageCompletion", "canonicalPrefixEvidenceValid",
      "func establishPrefixEvidence"]),
    (PREFIX, "PrefixInspection.swift", ["PrefixInspecting", "PrefixAcquisitionSource"]),
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


@guard("pageTitle must derive from presentation")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupView.swift")
    if "pageTitle" not in content:
        return []
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
    sections = re.split(r"\n(?=\s*(?:case|default)\b)", body)
    for section in sections:
        s = section.strip()
        if not s:
            continue
        if re.search(r"case\s+\.steamInstaller\b", s):
            if "return .installer" not in s:
                out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                           "steamInstaller case must return .installer")
        elif re.search(r"case\s+\.steamClient\b", s):
            if "return .client" not in s:
                out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                           "steamClient case must return .client")
        elif s.startswith("default"):
            if "return nil" not in s:
                out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                           "default case must return nil")
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
    if "static func production" not in content:
        return [f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: "
                "PrefixInspectAction.production missing"]
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
    if "InstallerNavigationFooter" not in body:
        out.append(f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                   "diagnostics page lacks InstallerNavigationFooter in its own body")
    if "coordinator.send" not in body:
        out.append(f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
                   "diagnostics page lacks coordinator.send callback")
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


@guard("canonicalPrefixEvidenceValid semantics incomplete")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    body = required_body(content, "var canonicalPrefixEvidenceValid",
                         "UltimateSetupCoordinator.canonicalPrefixEvidenceValid")
    required_tokens = ["prefixLayout", "prefixInspection", "isValid",
                       "canonicalURL(inspection.prefixURL)",
                       "canonicalURL(layout.root)", "=="]
    missing = [t for t in required_tokens if t not in body]
    if missing:
        return [f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                f"canonicalPrefixEvidenceValid missing {missing}"]
    # canonicalURL must canonicalize BOTH sides.
    cu_body = required_body(content, "func canonicalURL",
                            "UltimateSetupCoordinator.canonicalURL")
    if "standardizedFileURL" not in cu_body or "resolvingSymlinksInPath" not in cu_body:
        return [f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                "canonicalURL must use standardizedFileURL and resolvingSymlinksInPath"]
    return []


@guard("prefix acquisition branch evidence ordering violation")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        infra("required contract missing: UltimateSetupCoordinator.swift")
    body = required_body(content, "func createPrefix",
                         "UltimateSetupCoordinator.createPrefix")
    out = []
    # The production router must carry the matching source per branch.
    if "func establishExistingPrefixAcquisition" not in content:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "production acquisition router missing")
    else:
        router_body = required_body(
            content, "func establishExistingPrefixAcquisition",
            "UltimateSetupCoordinator.establishExistingPrefixAcquisition"
        )
        for src in (".existingCanonical", ".adoptedSteam"):
            if f"source: {src}" not in router_body:
                out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                           f"acquisition router branch {src} lacks matching evidence")
    # Router call must precede the Steam-ready early return in createPrefix.
    pos_router = body.find("establishExistingPrefixAcquisition")
    pos_ready = body.find("state = .steamReady")
    if pos_ready >= 0 and (pos_router < 0 or pos_router > pos_ready):
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "existing/adopted evidence not established before Steam-ready return")
    # Newly-initialized evidence must precede the prefixReady state change.
    if "source: .newlyInitialized" not in body:
        out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                   "createPrefix branch .newlyInitialized lacks evidence establishment")
    pos_new = body.find("source: .newlyInitialized")
    pos_ready2 = body.find("state = .prefixReady")
    if pos_new >= 0 and pos_ready2 >= 0 and pos_new > pos_ready2:
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
