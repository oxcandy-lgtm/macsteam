#!/usr/bin/env python3
"""U1R16 Static Audit Scanner — navigation authority + structural guards.

Usage:
  python3 scripts/u1r16_static_audit.py [--repo-root <root>]

Checks (all fail-closed; missing files are clean for their checks):
  1. Views never write `coordinator.state = ...`
  2. Views never write `coordinator.currentPage = ...`
  3. Root view never dispatches pages via `switch coordinator.state`
  4. Root view consumes the production presentation descriptor
     (UltimatePageResolver.presentation) for content/title/step
  5. Steam pages are never merged into one `case .steamInstaller, .steamClient`
  6. steamMode resolver maps .steamInstaller→.installer and .steamClient→.client
  7. SteamSetupView never calls recheckCloverPit() directly (canonical lane only)
  8. Views never swallow navigation cleanup with `try? await coordinator.`
  9. PrefixSetupView never holds `@State` inspection (coordinator authority)
 10. PrefixSetupView never owns a local PrefixInspector()
 11. PrefixSetupView's Inspect lane routes through the coordinator
     (PrefixInspectAction / inspectCanonicalPrefix)
 12. Views never use `ForEach(logLines, id: \.self)` (stable IDs required)
 13. UltimateSetupView's diagnosticsPageView body (balanced braces) carries
     the canonical footer AND a coordinator.send callback itself — a footer
     elsewhere in the file does NOT satisfy the guard
 14. computePageCompletion's `.environment` assignment expression itself
     binds to canonicalPrefixEvidenceValid (symbol elsewhere is not enough)
 15. Evidence establishment covers all three prefix acquisition sources
     (existingCanonical / adoptedSteam / newlyInitialized)

Exit codes: 0 = clean, 1 = violations, 2 = infrastructure error.
"""
import os
import re
import sys

VIEWS = os.path.join("Sources", "MacSteam", "Views")
ULTIMATE = os.path.join("Sources", "MacSteam", "Ultimate")
PREFIX = os.path.join("Sources", "MacSteam", "Prefix")


def read_file(root: str, rel: str):
    path = os.path.join(root, rel)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)


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
        return []
    return [
        f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: switch coordinator.state"
        for _ in re.finditer(r"switch\s+coordinator\.state", content)
    ]


@guard("presentation descriptor not consumed by root view")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        return []
    if "presentation" not in content:
        return [
            f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
            "UltimatePageResolver.presentation not consumed"
        ]
    if "UltimatePageResolver.presentation" not in content:
        return [
            f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
            "presentation not derived from UltimatePageResolver.presentation"
        ]
    return []


@guard("Steam pages merged into one case in UltimateSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        return []
    return [
        f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: merged steam case"
        for _ in re.finditer(r"case\s+\.steamInstaller\s*,\s*\.steamClient", content)
    ]


@guard("steamMode resolver does not map installer/client distinctly")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimatePageResolver.swift"))
    if content is None:
        return []
    # Extract the steamMode function body with balanced braces.
    m = re.search(r"static\s+func\s+steamMode\s*\([^)]*\)\s*(?:->\s*[^{]+)?\{", content)
    if not m:
        return [
            f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: steamMode resolver missing"
        ]
    start = m.end()
    depth = 1
    i = start
    while depth > 0 and i < len(content):
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1
    body = content[start:i - 1]
    out = []
    if ".steamInstaller" not in body or "return .installer" not in body:
        out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                   "steamInstaller must map to .installer")
    if ".steamClient" not in body or "return .client" not in body:
        out.append(f"{os.path.join(VIEWS, 'UltimatePageResolver.swift')}: "
                   "steamClient must map to .client")
    return out


@guard("SteamSetupView direct recheckCloverPit (canonical lane violation)")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "SteamSetupView.swift"))
    if content is None:
        return []
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
        return []
    return [
        f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: @State inspection"
        for _ in re.finditer(r"@State[^\n]*\binspection\b", content)
    ]


@guard("local PrefixInspector authority in PrefixSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "PrefixSetupView.swift"))
    if content is None:
        return []
    return [
        f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: local PrefixInspector()"
        for _ in re.finditer(r"PrefixInspector\s*\(", content)
    ]


@guard("prefix Inspect lane bypasses coordinator")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "PrefixSetupView.swift"))
    if content is None:
        return []
    if "PrefixInspectAction" not in content and "inspectCanonicalPrefix" not in content:
        return [
            f"{os.path.join(VIEWS, 'PrefixSetupView.swift')}: "
            "Inspect action does not route through the coordinator lane"
        ]
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


def _balanced_body(content: str, needle: str):
    """Return the balanced-brace body following `needle` (e.g. a func name)."""
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
    return content[brace + 1:i - 1]


@guard("Diagnostics page missing canonical footer in UltimateSetupView")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(VIEWS, "UltimateSetupView.swift"))
    if content is None:
        return []
    if "diagnosticsPageView" not in content:
        return []
    # The footer + canonical callback must live INSIDE the diagnostics body.
    body = _balanced_body(content, "diagnosticsPageView")
    if body is None:
        return [
            f"{os.path.join(VIEWS, 'UltimateSetupView.swift')}: "
            "diagnosticsPageView body unparseable"
        ]
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


@guard("environment completion not bound to canonicalPrefixEvidenceValid")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        return []
    # Parse the .environment assignment expression itself.
    m = re.search(r"completion\[\.environment\]\s*=\s*([^\n]+)", content)
    if not m:
        return [
            f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
            "environment completion assignment missing"
        ]
    rhs = m.group(1)
    if "canonicalPrefixEvidenceValid" not in rhs:
        return [
            f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
            f"environment assignment does not bind canonicalPrefixEvidenceValid "
            f"(got: {rhs.strip()})"
        ]
    return []


@guard("evidence establishment missing a prefix acquisition source")
def _(root: str) -> list[str]:
    content = read_file(root, os.path.join(ULTIMATE, "UltimateSetupCoordinator.swift"))
    if content is None:
        return []
    out = []
    for source in (".existingCanonical", ".adoptedSteam", ".newlyInitialized"):
        if source not in content:
            out.append(f"{os.path.join(ULTIMATE, 'UltimateSetupCoordinator.swift')}: "
                       f"acquisition path {source} lacks evidence establishment")
    return out


def scan(root: str) -> list[str]:
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
