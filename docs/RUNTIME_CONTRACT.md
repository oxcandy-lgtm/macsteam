# Runtime Artifact Contract — MacSteam

> **Version:** 1.0
> **Schema:** `Contracts/runtime-manifest.schema.json` (v1)
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## 1. RuntimeArtifactManifest Schema (v1)

Every distributable runtime artifact **must** be described by a `RuntimeArtifactManifest` document conforming to `Contracts/runtime-manifest.schema.json`.

### Required top-level fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | `const: 1` | Schema version identifier |
| `id` | string | Unique identifier for this runtime manifest |
| `version` | string | Version string of the runtime artifact |
| `hostArchitectures` | array | Host (build-machine) architectures |
| `runtimeArchitectures` | array | Target runtime architectures |
| `minimumMacOS` | string | Minimum macOS version (e.g. `11.0`, `14.0`) |
| `source` | object | Source identity and provenance |
| `license` | object | License identity and redistribution terms |
| `archive` | object | Archive identity and integrity metadata |
| `capabilities` | array | Capabilities this runtime provides |

---

## 2. SourceIdentity

The `source` field captures provenance:

```json
{
  "source": {
    "upstreamRepository": "https://github.com/example/wine.git",
    "upstreamCommit": "abc123def456...",
    "sourceArchiveSHA256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "patchsetSHA256": "01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805dcea546b",
    "buildRecipeSHA256": "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `upstreamRepository` | ✅ | URL of the upstream source repository |
| `upstreamCommit` | ✅ | Commit hash in upstream repository |
| `sourceArchiveSHA256` | ✅ | SHA-256 of the source archive |
| `patchsetSHA256` | ❌ | SHA-256 of the applied patchset (optional) |
| `buildRecipeSHA256` | ✅ | SHA-256 of the build recipe |

---

## 3. LicenseIdentity

The `license` field captures the licensing:

```json
{
  "license": {
    "spdx": "LGPL-2.1-or-later",
    "licenseFiles": ["COPYING", "LICENSE"],
    "noticeFiles": ["NOTICE"],
    "redistribution": {
      "mode": "reviewRequired"
    }
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `spdx` | ✅ | SPDX license identifier |
| `licenseFiles` | ✅ | Paths to license files in the artifact |
| `noticeFiles` | ✅ | Paths to notice/attribution files |
| `redistribution.mode` | ✅ | Redistribution mode (see [RedistributionClass](#4-redistributionclass-enum)) |

---

## 4. RedistributionClass Enum

| Value | Meaning |
|-------|---------|
| `allowed` | Redistribution is permitted without additional review |
| `allowedWithConditions` | Permitted with specific conditions (documented in manifest) |
| `reviewRequired` | Requires legal review before distribution |
| `forbidden` | Never redistributable |

---

## 5. ArchiveIdentity

The `archive` field captures the distributable artifact:

```json
{
  "archive": {
    "filename": "wine-8.0-macos-arm64.tar.gz",
    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "size": 52428800
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `filename` | ✅ | Filename of the distribution archive |
| `sha256` | ✅ | SHA-256 checksum of the archive |
| `size` | ✅ | Size in bytes |

---

## 6. RuntimeCapabilities Bitfield

The `capabilities` array lists runtime features. Standard capability tokens:

| Token | Description |
|-------|-------------|
| `windows-process` | Can run Windows executables (base capability) |
| `steam-client` | Supports Steam client functionality |
| `isolated-prefix` | Supports WINEPREFIX isolation |
| `d3d` | Direct3D translation support (any version) |
| `vulkan` | Vulkan support |
| `metal` | Metal support via MoltenVK or similar |

A runtime **must** declare `windows-process` as a baseline. All other capabilities are optional and depend on the runtime build configuration.

---

## 7. Installation Pipeline (Future)

When Managed Wine distribution is implemented, the installation pipeline will follow this contract:

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Verify  │ →  │  Acquire │ →  │  Verify  │ →  │  Atomic  │
│  Manifest│    │          │    │  SHA-256 │    │  Activate│
└──────────┘    └──────────┘    └──────────┘    └──────────┘
```

### Step 1 — Verify Manifest
- Confirm manifest is signed by a project release key.
- Validate manifest JSON against schema.
- Check that `redistribution.mode` is not `forbidden`.

### Step 2 — Acquire
- Download the archive from the URL specified in the manifest.
- Must use TLS with valid certificate verification.

### Step 3 — Verify SHA-256
- Compute SHA-256 of downloaded archive.
- Compare against `archive.sha256` in the manifest.
- Fail if mismatch (do not attempt installation).

### Step 4 — Atomic Activate
- Extract to a staging directory.
- Verify extracted content matches expected structure.
- Rename staging directory to final location atomically.
- On failure: remove staging directory; leave no partial state.

> **U1 note:** The installation pipeline is designed but not implemented. Runtime selection uses only user-provided runtimes in U1.

---

## 8. U1 Runtime Selection Contract

- Imported Wine is the canonical U1 runtime.
- The user selects/imports the runtime.
- System Wine may be discovered but is not selected by default for the U1 Steam path.
- Managed Wine is future/unavailable.
- CrossOver is not canonical.
- CrossOver is not required.
- CrossOver is not default-enabled.
- CrossOver is disabled by default.
- CrossOver requires explicit opt-in.
- CrossOver is lowest priority.
- CrossOver is never a prerequisite.
