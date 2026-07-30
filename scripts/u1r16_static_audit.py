#!/usr/bin/env python3
"""U1R16 Static Audit Scanner — coordinator.state assignment detection.

Usage:
  python3 scripts/u1r16_static_audit.py
  python3 scripts/u1r16_static_audit.py --root <fixture-root>
"""
import re
import sys
import os


DIRECT_STATE_WRITE = re.compile(
    r"\bcoordinator\.state\s*=(?!=)"
)

ACCEPTED_PATTERNS = [
    (r"\bcoordinator\.state\s*==\s*", "equality"),
    (r"\bcoordinator\.state\s*!=\s*", "inequality"),
]

FILE_PATTERNS = [
    re.compile(r"Views/"),
]


def is_comparison(text: str) -> bool:
    for pattern, _ in ACCEPTED_PATTERNS:
        if re.search(pattern, text):
            return True
    return False


def scan_file(path: str) -> list[dict]:
    violations = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                if DIRECT_STATE_WRITE.search(line):
                    violations.append({
                        "file": path,
                        "line": lineno,
                        "text": line.rstrip(),
                    })
    except (OSError, UnicodeDecodeError) as e:
        violations.append({
            "file": path,
            "line": 0,
            "text": f"ERROR: {e}",
        })
    return violations


def scan_root(root: str) -> list[dict]:
    errors = []
    if not os.path.isdir(root):
        print(f"ERROR: directory not found: {root}", file=sys.stderr)
        sys.exit(2)
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".swift"):
                path = os.path.join(dirpath, fn)
                errors.extend(scan_file(path))
    # Filter out false positives
    return [v for v in errors if not is_comparison(v["text"])]


def main():
    import argparse
    parser = argparse.ArgumentParser(description="U1R16 coordinator.state assignment scanner")
    parser.add_argument("--root", help="Custom root directory (for testing)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.normpath(os.path.join(script_dir, ".."))

    if args.root:
        violations = scan_root(args.root)
    else:
        views_dir = os.path.join(project_root, "Sources", "MacSteam", "Views")
        violations = scan_root(views_dir)

    if violations:
        for v in violations:
            rel = os.path.relpath(v["file"], project_root) if not args.root else v["file"]
            print(f"VIOLATION: {rel}:{v['line']}: {v['text']}")
        sys.exit(1)
    else:
        print("STATIC SCANNER PASSED — 0 coordinator.state assignment violations")
        sys.exit(0)


if __name__ == "__main__":
    main()
