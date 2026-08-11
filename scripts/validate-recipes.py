#!/usr/bin/env python3
"""Validate game recipe JSON files for security constraints."""
import json, sys, os, glob

failures = []
pattern = os.path.join(os.path.dirname(__file__), "..",
    "Sources", "MacSteam", "Resources", "Recipes", "*.json")
for path in glob.glob(pattern):
    with open(path) as f:
        r = json.load(f)
    name = os.path.basename(path)

    try:
        assert r.get("schemaVersion") == 2, f"{name}: schemaVersion != 2"
        assert "storeInstallation" in r, f"{name}: missing storeInstallation"
        assert r["storeInstallation"].get("redistribution") == "forbidden", \
            f"{name}: redistribution not forbidden"
    except AssertionError as e:
        print(f"  FAIL: {e}")
        failures.append(name)
        continue

    text = open(path).read()
    for op in ["runShell", "runSudo", "downloadArbitraryURL", "deleteHostPath"]:
        if op in text:
            print(f"  FAIL: {name} contains forbidden operation '{op}'")
            failures.append(f"{name}:{op}")

    if not failures:
        print(f"  OK: {name}")

if failures:
    print(f"\nFAILED: {len(failures)} issue(s)")
    sys.exit(1)
print("\nAll recipes pass security validation.")
