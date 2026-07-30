#!/usr/bin/env python3
"""U1R16 Static Audit Scanner — coordinator.state assignment detection.

Distinguishes:
  coordinator.state = .ready   → VIOLATION (assignment)
  coordinator.state == .ready  → ALLOWED (comparison)
  coordinator.state != .ready  → ALLOWED (comparison)
"""
import re
import sys
import os
import subprocess


DIRECT_STATE_WRITE = re.compile(
    r"\bcoordinator\.state\s*=(?!=)"
)

ACCEPTED_PATTERNS = [
    (r"\bcoordinator\.state\s*==\s*", "equality check"),
    (r"\bcoordinator\.state\s*!=\s*", "inequality check"),
]

FILE_INCLUSION_PATTERNS = [
    re.compile(r"Sources/MacSteam/Views/"),
]


def is_comparison(text: str) -> bool:
    """Check if a coordinator.state usage is a comparison, not assignment."""
    for pattern, _ in ACCEPTED_PATTERNS:
        if re.search(pattern, text):
            return True
    return False


def scan_file(path: str) -> list[dict]:
    """Scan a single file for coordinator.state violations."""
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


def main():
    """Run the static audit scanner over relevant paths."""
    errors = []
    
    # Discover Swift files in Views
    views_dir = os.path.join(os.path.dirname(__file__), "..", "Sources", "MacSteam", "Views")
    if not os.path.isdir(views_dir):
        errors.append(f"Directory not found: {views_dir}")
    else:
        for root, dirs, files in os.walk(views_dir):
            for fn in files:
                if fn.endswith(".swift"):
                    path = os.path.join(root, fn)
                    errors.extend(scan_file(path))

    # Filter out false positives (comparisons)
    violations = [v for v in errors if not is_comparison(v["text"])]

    if violations:
        for v in violations:
            rel = os.path.relpath(v["file"], os.path.join(os.path.dirname(__file__), ".."))
            print(f"VIOLATION: {rel}:{v['line']}: {v['text']}")
        sys.exit(1)
    else:
        print("STATIC SCANNER PASSED — 0 coordinator.state assignment violations")
        sys.exit(0)


if __name__ == "__main__":
    main()
