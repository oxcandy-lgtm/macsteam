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

- MacSteam scans for available runtimes (Imported Wine, System Wine, CrossOver).
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

- The user's existing Steam installation is detected.
- Steam is launched inside the prefix via:
  ```
  wine <prefix> steam.exe -applaunch 3314790
  ```
- MacSteam does **not** install Steam on behalf of the user.
- MacSteam does **not** access Steam credentials.

### Step 4 — CloverPit Launch

- If Steam detects CloverPit as installed (via `appmanifest_3314790.acf`), the game launches.
- If CloverPit is not yet installed, Steam's UI opens to the game page for installation.
- After installation, subsequent launches go directly to the game.

---

## 3. Runtime Requirements

| Requirement | Detail |
|-------------|--------|
| Primary capability | `steam-client` |
| Minimum runtime | Wine with working Steam client support |
| Supported adapters | ImportedWine, SystemWine, CrossOver |
| Managed Wine | Not available in U1 |

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
    "requiredCapabilities": ["steam-client"],
    "preferredRuntime": "imported-wine",
    "fallbackRuntimes": ["system-wine", "crossover"]
  },
  "graphics": {
    "preferred": "d3d-metal",
    "fallback": ["d3d-vulkan", "vulkan-metal"]
  },
  "prefix": {
    "id": "cloverpit",
    "windowsVersion": "win10",
    "isolation": "per-game"
  },
  "storeInstallation": {
    "installerMode": "user-selected-file",
    "installerProduct": "steam",
    "redistribution": "forbidden"
  },
  "launch": {
    "storeArguments": ["-applaunch", "3314790"]
  },
  "detection": {
    "manifestName": "appmanifest_3314790.acf",
    "executableCandidates": ["CloverPit.exe"]
  },
  "savePolicy": {
    "mode": "discover-only",
    "backupBeforeDestructiveRepair": false
  }
}
```

---

## 7. U1 Limitations

| Limitation | Detail |
|------------|--------|
| **Managed Wine** | Not available; only user-provided runtimes |
| **Destructive repair** | Disabled; prefix destruction is dry-run only |
| **Save snapshots** | Discovery mode only (no automated backup) |
| **Graphics adapters** | DXVK/MoltenVK not managed in U1 |
| **Multiple runtimes** | Basic detection only; no automatic download |
