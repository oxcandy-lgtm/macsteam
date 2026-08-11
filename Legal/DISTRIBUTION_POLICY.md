# Distribution Policy — MacSteam Ultimate

> **Version:** 1.0  
> **Applies to:** MacSteam Ultimate (cloverpit-u1)  
> **Effective:** 2024-07-01

## 1. Scope

This policy governs how MacSteam Ultimate source code and binaries may be distributed — directly by the project maintainers, by downstream packagers, or by end-users. It establishes clear boundaries for what may, may not, and must conditionally be redistributed.

---

## 2. MacSteam Source & Binaries (GPL-3.0-or-later)

MacSteam Ultimate itself is released under **GNU General Public License v3.0 or later**.

- **Source code:** Freely distributable. Must include the full GPL-3.0-or-later licence text and SPDX headers.
- **Binaries:** Freely distributable under the terms of GPL-3.0-or-later. Binary distributions **must** include or be accompanied by a written offer for Corresponding Source (see [SOURCE_OFFER_POLICY.md](./SOURCE_OFFER_POLICY.md)).
- **Installers / DMGs:** May be distributed under the same terms as the binaries they contain.
- **Package manager feeds (Homebrew, MacPorts, etc.):** Formulae and recipes may reference the official source tarballs or GitHub releases.

> **Permitted** ✅ Re-distribute MacSteam binaries as part of a GPL-compatible aggregate.
> **Required** ⚠️ Accompany with source offer (see §8).
> **Prohibited** ❌ Add additional restrictions beyond those in GPL-3.0-or-later.

---

## 3. Steam Client — No Redistribution

> **Policy:** **NEVER BUNDLE OR REDISTRIBUTE.**

The Steam Client is the proprietary software of **Valve Corporation**.

- ❌ MacSteam may not include, bundle, embed, or redistribute any part of the Steam Client.
- ❌ Installers may not download or stage the Steam Client on behalf of the user.
- ✅ Users may install their own copy of Steam and point MacSteam at it.
- ✅ MacSteam may detect an existing Steam installation and offer to use it.

The Steam Client must remain **user-obtained, user-installed, user-controlled**.

---

## 4. Game Assets — No Redistribution

> **Policy:** **NEVER BUNDLE OR REDISTRIBUTE.**

- ❌ No game assets (textures, models, audio, binaries, save files, configuration) owned by third parties may be distributed with MacSteam.
- ❌ MacSteam may not download or cache game assets.
- ✅ MacSteam may reference local game installations via user-selected file paths.
- ✅ MacSteam may display metadata (titles, icons) obtained through legitimate APIs or user-provided paths.

---

## 5. Apple GPTK / D3DMetal — No Redistribution

> **Policy:** **NEVER BUNDLE OR REDISTRIBUTE.**

**Apple Game Porting Toolkit (GPTK)** and **D3DMetal** are proprietary software of Apple Inc., subject to the Apple SDK Agreement and Xcode licence.

- ❌ GPTK and D3DMetal may not be bundled, embedded, or redistributed with MacSteam.
- ❌ Installers may not download, extract, or stage GPTK or D3DMetal.
- ✅ Future versions of MacSteam may offer a **detection adapter** that checks whether GPTK or D3DMetal is already present on the system and, if so, uses it transparently — without bundling, downloading, or transferring either component.

---

## 6. Microsoft DLLs and Fonts — No Redistribution

> **Policy:** **NEVER BUNDLE OR REDISTRIBUTE.**

- ❌ Microsoft redistributable DLLs (`msvcrt*.dll`, `vcruntime*.dll`, `msvcp*.dll`, etc.) may not be bundled with MacSteam.
- ❌ Microsoft fonts (Arial, Times New Roman, Courier New, Segoe UI, etc.) may not be bundled.
- ✅ Wine's built-in open-source replacements (e.g., `winecrt0`, `wine_msvcrt`) are acceptable as they are part of the Wine LGPL-2.1+ project.
- ✅ Microsoft-provided redistributable packages may be referenced in documentation as a user-installable dependency, subject to future review (see [PROPRIETARY_COMPONENTS.md](./PROPRIETARY_COMPONENTS.md)).

---

## 7. Wine Binary Distribution — Conditional

Wine (including Crossover Wine and upstream Wine) may be distributed as a separate, conditional binary package **only** when all the following requirements are met:

| # | Requirement | Detail |
|---|---|---|
| 1 | **Exact upstream commit** | The exact commit SHA from which the binary was built. |
| 2 | **Declared licence** | LGPL-2.1-or-later (or applicable Wine licence). |
| 3 | **Corresponding source** | Full source code matching the binary, either linked or offered. |
| 4 | **Patchset** | All patches applied on top of upstream, in a machine-readable format (a `.patch` or `.diff` file per patch). |
| 5 | **Build script** | A reproducible build script (e.g., `build-wine.sh`) listing every tool, flag, and environment variable. |
| 6 | **SHA-256 checksum** | An authoritative checksum of the distributed binary archive. |
| 7 | **SBOM** | A software bill of materials listing all constituent libraries and their licences. |

Wine binary packages that do not meet **all** seven requirements **must not** be offered for download.

---

## 8. Third-Party Binary Download Requirements

Any component that MacSteam downloads from the internet (runtime artifacts, engine components, helper tools) **must** satisfy:

1. **Manifest signing** — The download manifest (URL, version, checksums) must be signed by a project release key.
2. **TLS** — Every download must use HTTPS with valid server certificate verification.
3. **SHA-256 verification** — Downloaded content must be verified against the signed manifest before use.
4. **Atomic install** — Installation must be atomic: either the component is fully and correctly installed, or the operation fails cleanly with no partial state left behind.

Non-conforming downloads are **prohibited**.

---

## 9. Source Offer (GPL Compliance)

Any binary distribution of MacSteam (or of a GPL-licensed runtime component) must include a written offer to provide Corresponding Source. See [SOURCE_OFFER_POLICY.md](./SOURCE_OFFER_POLICY.md) for the standard offer text and procedures.

---

*For questions about distribution boundaries, contact the MacSteam project maintainers.*
