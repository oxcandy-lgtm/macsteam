# CloverPit U1 — Game Setup Guide

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)
> **Game:** CloverPit (Steam App ID 3314790)

## Overview

CloverPit is the target game for the MacSteam Ultimate U1 release. This document describes the specific setup and launch flow for CloverPit.

---

## 1. Game Identification

| Property | Value |
|----------|-------|
| **Display name** | CloverPit |
| **Steam App ID** | 3314790 |
| **Store** | Steam |
| **Runtime requirement** | Wine with `steam-client` capability |
| **Redistribution** | Forbidden (user-obtained only) |

---

## 2. Setup Flow (4 Steps)

The setup process is linear and each step must complete before the next begins.

```
Step 1: Runtime → Step 2: Prefix → Step 3: Steam → Step 4: CloverPit
```

### Step 1 — Runtime Selection

- Canonic runtime preference: **Imported Wine**.
- Recipe fallback declaration: **System Wine**.
- Effective U1 selection: **Imported Wine**.
- System Wine is not the U1 canonical path: a discovered capability may exist, but the U1 Steam selection excludes it by default.
- Managed Wine: **future / unavailable**.
- CrossOver is **not** a canonical recipe dependency.
- The selected runtime must advertise the `steam-client` capability.
- If no suitable runtime is found, the user is prompted to import one.

### Step 2 — Prefix Creation

- A dedicated Wine prefix is created at:
  ```
  ~/Library/Application Support/MacSteam/Prefixes/cloverpit/
  ```
- Initialized with `wineboot -u` to create a clean Windows environment.
- Windows version set to `win10`.
- Basic registry keys are set (Steam-specific configuration).

### Step 3 — Steam Installation

- The user obtains a Steam installer `.exe` independently.
- MacsTeam does **not** bundle or download the Steam installer.
- The user selects the installer file; MacsTeam verifies it (regular file, `.exe`, non-empty, SHA-256 evidence) and runs the selected installer inside the canonical prefix with the selected runtime.
- MacSteam does **not** access Steam credentials.

### Step 4 — CloverPit Launch

- If Steam detects CloverPit as installed (via `appmanifest_3314790.acf`), the game launches.
- If CloverPit is not yet installed, Steam's UI opens to the game page for installation.
- After installation, subsequent launches go directly to the game.

---

## 3. Runtime Requirements

| Requirement | Detail |
|-------------|--------|
| Canonical runtime preference | Imported Wine |
| Recipe fallback declaration | System Wine |
| Effective U1 selection | Imported Wine |
| System Wine | Discovered capability may exist, but the U1 Steam selection excludes it by default |
| Managed Wine | Future / unavailable |
| CrossOver | Not a canonical recipe dependency |
| Primary capability | `steam-client` |
| Graphics | WineD3D |

---

## 4. Detection

### Steam Detection

MacSteam detects Steam installation by scanning standard locations:

- `~/Library/Application Support/Steam/`
- `/Applications/Steam.app/`
- User-selected path

### CloverPit Detection

CloverPit is detected as installed when both:

1. **Manifest file exists:**
   ```
   ~/Library/Application Support/Steam/steamapps/appmanifest_3314790.acf
   ```
2. **Executable exists:**
   ```diff
   + CloverPit.exe
   ```
   Located under the Steam library path for app 3314790.

---

## 5. Launch Command

```
wine64 \
  <prefix>/drive_c/Program Files (x86)/Steam/steam.exe \
  -applaunch 3314790
```

**Constraints:**
- Must use `Process.arguments` array (no string concatenation).
- WINEPREFIX must be set in environment.
- Working directory must be the prefix drive_c root or Steam directory.
- No shell wrapper (`/bin/sh -c` is forbidden).

---

## 6. Recipe Fields (v2 schema)

```json
{
  "schemaVersion": 2,
  "id": "cloverpit",
  "displayName": "CloverPit",
  "store": {
    "type": "steam",
    "appId": "3314790"
  },
  "runtime": {
    "requiredCapabilities": [
      "windows-process",
      "steam-client",
      "isolated-prefix"
    ],
    "preferredRuntime": "imported-wine",
    "fallbackRuntimes": [
      "system-wine"
    ]
  },
  "graphics": {
    "preferred": "wined3d",
    "fallback": []
  },
  "prefix": {
    "id": "cloverpit",
    "windowsVersion": "win10",
    "isolation": "per-game"
  },
  "storeInstallation": {
    "installerMode": "user-selected-file",
    "installerProduct": "steam-client",
    "redistribution": "forbidden"
  },
  "launch": {
    "storeArguments": [
      "-applaunch",
      "3314790"
    ]
  },
  "detection": {
    "manifestName": "appmanifest_3314790.acf",
    "executableCandidates": [
      "CloverPit.exe"
    ]
  },
  "savePolicy": {
    "mode": "discover-only",
    "backupBeforeDestructiveRepair": true
  }
}
```

The recipe JSON above is the bundle-fresh serialized mirror of the canonical runtime authority (`CloverPitRecipeAuthority.canonical`), enforced by CI.

---

## 7. U1 Limitations

| Limitation | Detail |
|------------|--------|
| **Managed Wine** | Future / unavailable; only user-provided runtimes |
| **Save policy** | Discovery mode only (`discover-only`), with `backup-before-destructive-repair: true` |
| **Graphics adapters** | WineD3D preferred; DXVK/MoltenVK not managed in U1 |
| **Multiple runtimes** | Basic detection only; no automatic download |
