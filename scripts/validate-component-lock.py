#!/usr/bin/env python3
"""Validate component-lock.json structure."""
import json, sys

with open("Sources/MacSteam/Resources/Legal/component-lock.json") as f:
    lock = json.load(f)

assert lock.get("schemaVersion") == 1, f"schemaVersion: {lock.get('schemaVersion')}"
ids = [c["id"] for c in lock.get("components", [])]
for required in ["wine", "steam-client", "dxvk-macos", "moltenvk", "d3dmetal"]:
    assert required in ids, f"Missing component: {required}"
print(f"component-lock.json valid ({len(ids)} components)")
print("  ids:", ", ".join(ids))
