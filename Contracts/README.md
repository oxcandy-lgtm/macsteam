# MacSteam Ultimate — Contracts

This directory contains JSON Schema (draft-07) definitions for the MacSteam
configuration and data interchange formats. Each schema defines the shape,
constraints, and versioning contract for a specific document type used across
the MacSteam runtime ecosystem.

## Schema files

| File | Purpose |
|---|---|
| `game-recipe.schema.json` (v2) | Game recipe configuration describing how a Windows game is set up and launched on macOS — store metadata, runtime requirements, prefix settings, detection rules, and save policy. |
| `runtime-manifest.schema.json` (v1) | Runtime artifact manifest describing a packaged runtime build — host/runtime architectures, source provenance (repository, commit, checksums), licensing terms, archive integrity, and capability declarations. |
| `artifact-source.schema.json` (v1) | Source identity metadata for downloaded artifacts — provider mechanism, repository probe status, git commit references, secret scan and credential output counts, and optional bundle checksum. |
| `compatibility-report.schema.json` (v1) | Per-game runtime compatibility status — runtime and game identifiers, compatibility status, detection method, timestamp, and associated errors/warnings. |
| `save-boundary.schema.json` (v1) | Save data boundary discovery results — candidate paths with confidence levels, confirmed paths, discovery status, and timestamp. |

## Versioning

Each schema includes a top-level `schemaVersion` field set with a `const`
keyword to its schema revision number. This enables consumers to validate that
a document matches exactly the schema revision they expect. Documents with an
unexpected `schemaVersion` can be rejected or routed to an appropriate
migration path.

- **game-recipe**: version 2
- **runtime-manifest**: version 1
- **artifact-source**: version 1
- **compatibility-report**: version 1
- **save-boundary**: version 1

## Usage

These schemas are compatible with any JSON Schema validator supporting
draft-07. For example, using `ajv` (Node.js):

```bash
ajv validate -s Contracts/game-recipe.schema.json -d path/to/recipe.json
```

Or with Python's `json` + `jsonschema`:

```python
import json, jsonschema

with open("Contracts/game-recipe.schema.json") as f:
    schema = json.load(f)

with open("path/to/recipe.json") as f:
    doc = json.load(f)

jsonschema.validate(doc, schema)
```
