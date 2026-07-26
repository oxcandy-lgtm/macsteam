# Component Licensing — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## 1. Component Lock Registry

Every third-party component that MacSteam depends on — whether bundled, downloaded, or detected — is registered in:

```
Sources/MacSteam/Resources/Legal/component-lock.json
```

### Schema (v1)

```json
{
  "schemaVersion": 1,
  "components": [
    {
      "id": "wine",
      "displayName": "Wine",
      "version": null,
      "upstreamCommit": null,
      "license": "LGPL-2.1-or-later",
      "redistribution": "review-required",
      "bundled": false,
      "binarySha256": null,
      "sourceReference": null,
      "patchsetReference": null
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Canonical component identifier |
| `displayName` | string | Human-readable name |
| `version` | string\|null | Known version (null if not yet determined) |
| `upstreamCommit` | string\|null | Upstream commit SHA |
| `license` | string | SPDX license identifier or "Proprietary" |
| `redistribution` | enum | One of: `"allowed"`, `"review-required"`, `"forbidden"`, `"forbidden-until-reviewed"` |
| `bundled` | boolean | Currently bundled in MacSteam distribution? |
| `binarySha256` | string\|null | SHA-256 of bundled binary (null if not bundled) |
| `sourceReference` | string\|null | URL to upstream source |
| `patchsetReference` | string\|null | URL to MacSteam patchset (if any) |

---

## 2. DistributionGate Evaluation

When MacSteam considers distributing (bundling or downloading) a component, DistributionGate evaluates:

1. **Is the component registered?** — If not in `component-lock.json`, reject.
2. **What is the redistribution field?**
   - `"allowed"` → proceed
   - `"review-required"` → require legal approval before proceeding
   - `"forbidden-until-reviewed"` → blocked; requires legal review first
   - `"forbidden"` → blocked permanently
3. **Is it bundled and not allowed?** — If `bundled` is true but redistribution is not `"allowed"`, reject.
4. **Does the distribution-gate CI check pass?** — CI must pass before merge.

### Current U1 component states

| Component | Redistribution | Bundled in U1? |
|-----------|---------------|----------------|
| `wine` | `review-required` | ❌ No |
| `dxvk-macos` | `review-required` | ❌ No |
| `moltenvk` | `review-required` | ❌ No |
| `steam-client` | `forbidden` | ❌ No |
| `d3dmetal` | `forbidden-until-reviewed` | ❌ No |

---

## 3. License File Requirements

Each component's license files must be present in one of these locations:

| Location | For |
|----------|-----|
| `Legal/<component-id>-LICENSE.md` | Bundled third-party components |
| `Legal/<component-id>-NOTICE.md` | Components requiring attribution |
| `THIRD_PARTY_NOTICES.md` | Consolidated notices for all components |
| `LICENSE` | MacSteam's own license (GPL-3.0-or-later) |

### License validation (CI)

The CI pipeline checks:

1. For each component in `component-lock.json`, a corresponding license file exists in `Legal/`.
2. `THIRD_PARTY_NOTICES.md` references all components with attribution requirements.
3. No license file is empty.

---

## 4. Source Offer Policy Reference

For GPL- and LGPL-licensed components, redistribution must include or be accompanied by a Corresponding Source offer.

See [Legal/SOURCE_OFFER_POLICY.md](../Legal/SOURCE_OFFER_POLICY.md) for:

- The standard written offer text
- Placement requirements in binary distributions
- How to obtain exact source for a release
- Compliance checklist

### Specific notes for Wine (LGPL-2.1-or-later)

Wine's LGPL-2.1-or-later license requires:

- A written offer for Corresponding Source when binaries are distributed.
- Notification of the license (already in `component-lock.json`).
- Preservation of copyright notices.
- Dynamic linking (not static) to allow replacement.

---

## 5. Adding a New Component

To add a new component:

1. Create an entry in `component-lock.json` with all required fields.
2. Add license file(s) to `Legal/`.
3. Update `THIRD_PARTY_NOTICES.md` if attribution is required.
4. Update `Legal/DISTRIBUTION_POLICY.md` if the component changes distribution boundaries.
5. If redistributing, create a `RuntimeArtifactManifest`.
6. Run `scripts/distribution-gate.sh` to validate.
7. Submit for review per [Legal/COMPONENT_POLICY.md §6](../Legal/COMPONENT_POLICY.md).
