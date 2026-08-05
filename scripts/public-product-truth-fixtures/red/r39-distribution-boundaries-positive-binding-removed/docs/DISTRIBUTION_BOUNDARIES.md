# Distribution Boundaries — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)
> **Policy reference:** [Legal/DISTRIBUTION_POLICY.md](../Legal/DISTRIBUTION_POLICY.md)

## 1. MacSteam Source (GPL-3.0-or-later)

| Aspect | Detail |
|--------|--------|
| **License** | GPL-3.0-or-later |
| **Redistribution** | Freely distributable |
| **Bundled** | ✅ Yes — source is the primary distribution artifact |
| **Requirements** | Include full GPL-3.0-or-later text; SPDX headers on all source files |
| **Binary distribution** | Must include source offer per GPL §6 |

---

## 2. Steam Client

| Aspect | Detail |
|--------|--------|
| **License** | Proprietary (Valve Corporation) |
| **Redistribution** | **Forbidden** |
| **Bundled** | ❌ Never bundled |
| **User-obtained** | ✅ Yes — user installs their own copy |
| **Component-lock** | `component-lock.json` entry exists with `redistribution: "forbidden"` |

- MacSteam may detect an existing Steam installation.
- MacSteam may launch Steam via the detected runtime.
- MacSteam may **not** download, bundle, or redistribute Steam in any form.

---

## 3. CloverPit

| Aspect | Detail |
|--------|--------|
| **License** | Proprietary |
| **Redistribution** | **Forbidden** |
| **Bundled** | ❌ Never bundled |
| **User-obtained** | ✅ Yes — user purchases on Steam and installs normally |

- CloverPit is a third-party game; all rights belong to its publisher.
- MacSteam only provides the runtime orchestration to launch it.
- The recipe's `storeInstallation.redistribution` field is set to `"forbidden"`.

---

## 4. Wine

| Aspect | Detail |
|--------|--------|
| **License** | LGPL-2.1-or-later (upstream Wine) |
| **Redistribution** | Conditional — see [Legal/DISTRIBUTION_POLICY.md §7](../Legal/DISTRIBUTION_POLICY.md) |
| **Bundled** | ❌ Not in U1; future conditional distribution via artifacts |

**U1 status:** Wine is user-provided only (Imported, System, or CrossOver). Managed Wine distribution is a future capability that will require:

1. Exact upstream commit SHA
2. Declared LGPL-2.1-or-later license
3. Corresponding source offer
4. Patchset documentation
5. Reproducible build script
6. SHA-256 checksum
7. Software bill of materials (SBOM)

---

## 5. DXVK-macOS

| Aspect | Detail |
|--------|--------|
| **License** | Zlib |
| **Redistribution** | Review-required (component-lock) |
| **Bundled** | ❌ Not in U1 |

**U1 status:** DXVK-macOS is registered in `component-lock.json` with `redistribution: "review-required"` but is not bundled or distributed. Future adapter support only.

---

## 6. MoltenVK

| Aspect | Detail |
|--------|--------|
| **License** | Apache-2.0 |
| **Redistribution** | Review-required (component-lock) |
| **Bundled** | ❌ Not in U1 |

**U1 status:** Registered in `component-lock.json`; not bundled. Future adapter support only.

---

## 7. D3DMetal / Game Porting Toolkit (GPTK)

| Aspect | Detail |
|--------|--------|
| **License** | Proprietary / Apple terms |
| **Redistribution** | **Forbidden** (component-lock: `forbidden-until-reviewed`) |
| **Bundled** | ❌ Never bundled |
| **User-obtained** | ✅ Yes — via Apple (part of macOS / Xcode) |

- See [GPTK_BOUNDARY.md](./GPTK_BOUNDARY.md) for full boundary details.
- Future detection adapter design only — no bundling at any point.

---

## 8. Microsoft Components

| Aspect | Detail |
|--------|--------|
| **License** | Proprietary (Microsoft) |
| **Redistribution** | **Forbidden** |
| **Bundled** | ❌ Not in U1, never without explicit legal review |
| **Replacement** | Wine's built-in open-source equivalents (`wine_msvcrt`, etc.) are acceptable |

Microsoft redistributables (VC++ runtimes, DirectX, fonts) are not distributed with MacSteam. Wine's built-in replacements fill these roles. Future consideration of Microsoft-provided redist packages would require legal review.

---

## 9. What Must Be Done Before Redistributing Any Component

Before any component is distributed (bundled or downloaded by MacSteam):

1. **Review `component-lock.json`** — Confirm the component's `redistribution` field allows distribution.
2. **Legal review** — If `redistribution` is `"reviewRequired"` or `"forbidden-until-reviewed"`, obtain written legal approval.
3. **Update manifest** — Create a `RuntimeArtifactManifest` per `Contracts/runtime-manifest.schema.json`.
4. **Update distribution-gate.sh** — Ensure CI distribution gate allows the new component.
5. **Update SBOM** — Record the component in the software bill of materials.
6. **Source offer** — If GPL/LGPL, ensure Corresponding Source offer is satisfied.

---

## 10. Current MacsTeam Distribution Status

- The current executable distribution is a Swift Package development build.
- Current use is through `swift run` or Xcode.
- No downloadable `.app` bundle is available.
- Code-signing is not complete.
- Notarization is not complete.
- No packaged ZIP/DMG/release is available.
- Source distribution remains governed by GPL-3.0-or-later.
