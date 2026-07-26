# Proprietary Components — Registry & Boundaries

> **Version:** 1.0  
> **Applies to:** MacSteam Ultimate (cloverpit-u1)  
> **Last updated:** 2024-07-01

This document registers every proprietary component known to be relevant to MacSteam Ultimate and defines the redistribution boundary for each.

---

## Registry

| # | Component | Owner | License Type | Redistribution Policy | U1 Status |
|---|---|---|---|---|---|
| 1 | Steam Client | Valve Corporation | Proprietary (EULA) | **Never bundled.** User-obtained only. MacSteam may detect an existing Steam installation and reference its Steamworks API via file-selection. | **In scope** — detection and file-selection paths exist in U1. |
| 2 | CloverPit | CloverPit Ltd. | Proprietary | **Never bundled.** Obtained by the user through the Steam Store. MacSteam may reference the installed CloverPit runtime at a user-provided path. | **In scope** — user-provided path resolution implemented in U1. |
| 3 | D3DMetal | Apple Inc. | Proprietary (Apple SDK Agreement) | **Never bundled.** D3DMetal is part of macOS. MacSteam may detect its presence in the OS (future detection adapter). No download, transfer, or staging. | **Not in U1** — detection adapter deferred. |
| 4 | Game Porting Toolkit (GPTK) | Apple Inc. | Proprietary (Apple SDK Agreement) | **Never bundled.** GPTK is an Apple developer tool. MacSteam may detect its presence (future detection adapter). No download, transfer, or staging. | **Not in U1** — detection adapter deferred. |
| 5 | Microsoft VC++ Redistributable | Microsoft Corporation | Proprietary (MS EULA) | **Not bundled in U1.** User-installable dependency. May be referenced in documentation. Requires formal legal review before any future bundling. | **Not in U1** — review required for future. |

---

## Detailed Boundaries

### 1. Steam Client (Valve Corporation)

| Field | Value |
|---|---|
| **Owner** | Valve Corporation |
| **License** | Steam Subscriber Agreement / Proprietary EULA |
| **SPDX** | N/A (not open source) |
| **Source availability** | Closed source |
| **Bundling in app bundle** | ❌ Prohibited |
| **Bundling in installer/DMG** | ❌ Prohibited |
| **Bundling in package feed** | ❌ Prohibited |
| **User-obtained** | ✅ Required (user installs Steam themselves) |
| **Detection in U1** | ✅ Steam installation directory may be auto-detected |
| **File-selection in U1** | ✅ User may manually select their Steam folder |
| **API usage** | ✅ Steamworks API may be used when Steam is running |
| **Required attribution** | "Steam" is a trademark of Valve Corporation |

### 2. CloverPit (CloverPit Ltd.)

| Field | Value |
|---|---|
| **Owner** | CloverPit Ltd. |
| **License** | Proprietary (per CloverPit EULA, obtained via Steam) |
| **SPDX** | N/A |
| **Source availability** | Closed source |
| **Bundling in app bundle** | ❌ Prohibited |
| **Bundling in installer/DMG** | ❌ Prohibited |
| **Bundling in package feed** | ❌ Prohibited |
| **User-obtained** | ✅ Required (user purchases CloverPit on Steam and installs through it) |
| **Path resolution in U1** | ✅ MacSteam reads the user-provided CloverPit path at launch |
| **Required attribution** | "CloverPit" is a trademark of its respective owner |

### 3. D3DMetal (Apple Inc.)

| Field | Value |
|---|---|
| **Owner** | Apple Inc. |
| **License** | Proprietary — distributed as part of macOS; no separate redistribution licence |
| **SPDX** | N/A |
| **Source availability** | Closed source |
| **Bundling** | ❌ Prohibited |
| **Detection adapter** | 🔄 Planned (future release; not in U1) |
| **Consumer of D3DMetal** | Wine/DXVK stage the D3DMetal.framework through Apple's `gameportingtoolkit` — MacSteam does not invoke D3DMetal directly |
| **Required attribution** | "Apple", "macOS", and "D3DMetal" are trademarks of Apple Inc. |

### 4. Game Porting Toolkit — GPTK (Apple Inc.)

| Field | Value |
|---|---|
| **Owner** | Apple Inc. |
| **License** | Proprietary — Apple SDK Agreement; Xcode licence |
| **SPDX** | N/A |
| **Source availability** | Closed source (Apple Developer account required) |
| **Bundling** | ❌ Prohibited |
| **Detection adapter** | 🔄 Planned (future release; not in U1) |
| **Required attribution** | "Game Porting Toolkit" is a trademark of Apple Inc. |

### 5. Microsoft VC++ Redistributable (Microsoft Corporation)

| Field | Value |
|---|---|
| **Owner** | Microsoft Corporation |
| **License** | Microsoft EULA — redistributable under specific terms (subject to version) |
| **SPDX** | N/A |
| **Source availability** | Closed source |
| **Bundling in U1** | ❌ Not bundled |
| **Future bundling** | 🔄 Requires formal legal review. The VC++ Redist EULA permits redistribution under certain conditions, but the project has not yet conducted a review. |
| **Status** | Documented as a user-installable dependency |

---

## Adding New Entries

To add a new proprietary component to this registry:

1. Open a PR that adds the entry in the table above and the corresponding detailed-boundaries section.
2. The PR must include evidence of the component's licence terms (EULA, licence file, or written correspondence).
3. Legal review is required before merge.
4. Update `component-lock.json` if the component has any distributable counterpart.

---

*Maintained by the MacSteam project. Corrections and additions should be submitted via pull request.*
