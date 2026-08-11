#!/usr/bin/env python3
"""Validate JSON fixtures against their schemas."""
import json, os, sys, glob

failures = []

def check(label, cond, detail=""):
    if cond:
        print(f"  ✓ {label}")
    else:
        print(f"  FAIL: {label} {'— ' + detail if detail else ''}")
        failures.append(label)

fixtures_dir = os.path.join(os.path.dirname(__file__), "..", "Tests", "MacSteamTests", "Fixtures")

# Map fixture → expected schema (if applicable)
schema_map = {
    "valid-game-recipe.json": "Contracts/game-recipe.schema.json",
    "runtime-manifest-fixture.json": "Contracts/runtime-manifest.schema.json",
    "artifact-source-fixture.json": "Contracts/artifact-source.schema.json",
    "save-boundary-fixture.json": "Contracts/save-boundary.schema.json",
    "compatibility-report-fixture.json": "Contracts/compatibility-report.schema.json",
}

for fixture_name, schema_path in schema_map.items():
    fixture_path = os.path.join(fixtures_dir, fixture_name)
    if not os.path.exists(fixture_path):
        check(f"{fixture_name} exists", False, "file not found")
        continue

    with open(fixture_path) as f:
        try:
            data = json.load(f)
            check(f"{fixture_name} valid JSON", True)
        except json.JSONDecodeError as e:
            check(f"{fixture_name} valid JSON", False, str(e))
            continue

    schema_abs = os.path.join(os.path.dirname(__file__), "..", schema_path)
    if not os.path.exists(schema_abs):
        check(f"{fixture_name} → {schema_path} (schema missing)", False, "schema not found")
        continue

    with open(schema_abs) as f:
        schema = json.load(f)

    # Static schema checks: const values, required fields
    if "required" in schema:
        missing = [r for r in schema["required"] if r not in data]
        if missing:
            check(f"{fixture_name} required fields", False, f"missing: {missing}")
        else:
            check(f"{fixture_name} required fields present", True)

    if "properties" in schema and "schemaVersion" in schema["properties"]:
        cv = schema["properties"]["schemaVersion"].get("const")
        if cv is not None:
            check(f"{fixture_name} schemaVersion={cv}", data.get("schemaVersion") == cv,
                  f"got {data.get('schemaVersion')}")

if failures:
    print(f"\nFAILED: {len(failures)} issue(s)")
    sys.exit(1)
else:
    print(f"\nAll fixtures passed.")
    sys.exit(0)
