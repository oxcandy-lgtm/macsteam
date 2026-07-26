# Ultimate Architecture — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)
> **Last updated:** 2024-07-01

## 1. What MacSteam Is

MacSteam is an **independent, open-source (GPL-3.0-or-later) runtime manager** for macOS that detects compatible Windows gaming runtimes and launches selected Windows games (Steam-purchased, user-obtained) through those runtimes. It is **not** a game store, a game emulator, or a Steam client—it orchestrates existing tooling.

MacSteam is:

- **Independent** — Not affiliated with Valve, Apple, CodeWeavers, or any game publisher.
- **OSS** — Licensed GPL-3.0-or-later; source is the primary distribution artifact.
- **A runtime manager** — It selects, validates, and invokes the appropriate runtime (Wine, CrossOver, etc.) for a given game.
- **A recipe engine** — Game definitions are declarative JSON recipes, not code.
- **Privacy-first** — All paths are redacted before logging; logs are local-only.

---

## 2. Overall Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        SwiftUI UI                           │
│   LauncherView / DiagnosticsView / LibraryView / Settings   │
└────────────────────────┬────────────────────────────────────┘
                         │ Command pattern
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                       GameManager                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ RecipeLoader │  │ Runtime      │  │ StoreDetector    │  │
│  │ (.json)      │  │ Registry     │  │ (Steam / local)  │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ PrefixManager│  │ Diagnostics  │  │ ProcessRunner    │  │
│  │              │  │ Store       │  │ (Process.exec)   │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                     RuntimeRegistry                           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                  Adapters                             │   │
│  │  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌──────────┐  │   │
│  │  │ Managed  │ │ Imported │ │ System │ │CrossOver │  │   │
│  │  │ Wine     │ │ Wine     │ │ Wine   │ │          │  │   │
│  │  └──────────┘ └──────────┘ └────────┘ └──────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                      PrefixManager                           │
│  ~/Library/Application Support/MacSteam/Prefixes/<game-id>/ │
│  prefix/ · metadata/ · snapshots/ · logs/ · user-overlay/  │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                       ProcessRunner                          │
│  wine <prefix> steam.exe -applaunch <appid>                  │
│  No shell invocation · No sudo · No string concatenation     │
└─────────────────────────────────────────────────────────────┘
```

### Layer descriptions

| Layer | Responsibility |
|-------|---------------|
| **SwiftUI UI** | LauncherView, DiagnosticsView, LibraryView, Settings. Uses Command pattern to talk to GameManager; never calls runtimes directly. |
| **GameManager** | Orchestrates game launch: loads recipe, resolves runtime, creates prefix, detects Steam install, builds launch command. |
| **RuntimeRegistry** | Holds all registered runtime adapters and selects the best match for a game's required capabilities. |
| **Adapters** | Each adapter wraps a specific runtime backend: ManagedWine (downloaded and managed by MacSteam), ImportedWine (user-provided .app), SystemWine (from PATH), CrossOver (detected CrossOver.app). |
| **PrefixManager** | Manages Wine prefix lifecycle: creation, structure, metadata, snapshots, safe destruction. |
| **ProcessRunner** | The only component that creates OS processes. Enforces ExecutionBoundary: no shell, no sudo, no string-command concatenation, no arbitrary URL downloads. |

---

## 3. Runtime Priority Chain

When a game recipe specifies runtime requirements, MacSteam evaluates adapters in this priority order:

1. **Managed Wine** — A Wine build downloaded and managed by MacSteam (future capability; U1 uses user-provided runtimes only).
2. **Imported Wine** — A user-provided `wine64` binary (e.g., from a bottled build) selected via the UI.
3. **System Wine** — Wine installed via Homebrew, MacPorts, or directly on PATH.
4. **CrossOver** — The CrossOver.app bundle, if detected on the system.

The first adapter whose capabilities match the recipe's `requiredCapabilities` is selected.

**U1 constraint:** Only user-detected runtimes (Imported, System, CrossOver) are supported. Managed Wine download/installation is deferred.

---

## 4. Distribution Boundaries

| Component | Bundled? | User-obtained? | License |
|-----------|----------|---------------|---------|
| MacSteam source | ✅ Yes | — | GPL-3.0-or-later |
| MacSteam binaries | ✅ Yes | — | GPL-3.0-or-later |
| Steam Client | ❌ No | ✅ Yes, user-installed | Proprietary |
| CloverPit | ❌ No | ✅ Yes, via Steam | Proprietary |
| Wine (runtime) | ❌ No (U1) | ✅ Yes, user-provided | LGPL-2.1-or-later |
| DXVK-macOS | ❌ No (U1) | ❌ No (U1) | Zlib |
| MoltenVK | ❌ No (U1) | ❌ No (U1) | Apache-2.0 |
| D3DMetal / GPTK | ❌ No | ❌ Never bundled | Apple proprietary |
| Microsoft DLLs | ❌ No | ❌ Not in U1 | Proprietary |

Full details: [DISTRIBUTION_BOUNDARIES.md](./DISTRIBUTION_BOUNDARIES.md)

---

## 5. Security Model

| Gate | What it enforces |
|------|-----------------|
| **ExecutionBoundary** | Executable location, working directory, WINEPREFIX, environment allow-list. |
| **PathBoundary** | Path traversal prevention for recipes and user-provided paths. |
| **SymlinkValidator** | Symlink escape detection before following any path. |
| **ArtifactVerifier** | SHA-256 verification of downloaded artifacts (future use). |
| **DistributionGate** | Ensures no forbidden components (Steam, D3DMetal, etc.) are bundled. |

### Hard rules

- No shell invocation (`/bin/sh -c` is forbidden).
- No sudo elevation.
- No string-command concatenation (use `Process.arguments` array).
- No arbitrary URL downloads.
- No credential output in logs or receipts.

Full details: [SECURITY_BOUNDARIES.md](./SECURITY_BOUNDARIES.md)

---

## 6. Recipe System

Games are defined by declarative JSON files conforming to `game-recipe.schema.json` v2.

### RecipeOperation DSL

Recipes describe operations through a restricted DSL with these allow-listed operations:

- `setWindowsVersion` — Set the prefix Windows version
- `installComponent` — Install a Wine component (e.g., `steam`)
- `setRegistryKey` — Set a registry key/value
- `runInstaller` — Run a known installer (only under prefix, with known executable)
- `copyFile` — Copy a file from store installation to prefix
- `deletePrefixFile` — Delete a file within the prefix

**Forbidden in recipes:**
- `runShell` — No shell commands
- `runSudo` — No privilege escalation
- `downloadArbitraryURL` — No uncontrolled downloads
- `deleteHostPath` — No deletions outside the prefix

Full details: [GAME_RECIPE_CONTRACT.md](./GAME_RECIPE_CONTRACT.md)

---

## 7. UI Layer

The UI follows a **Command pattern**:

- `LaunchGameCommand` — Triggers the full launch pipeline
- `ImportRuntimeCommand` — Opens a file picker for user-provided Wine
- `DetectSteamCommand` — Scans for Steam installation
- `DestroyPrefixCommand` — Safely destroys a prefix (U1: dry-run only)
- `RestoreSnapshotCommand` — Restores from a prefix snapshot

Each command is a value type that the UI creates and passes to GameManager. The UI never touches runtime adapters or process creation directly.

---

## 8. Key Design Decisions

1. **Protocol-oriented runtime abstraction** — `CompatibilityRuntime` protocol allows adding new runtimes without changing GameManager or recipes.
2. **Recipe-driven game definitions** — Every game is defined by a JSON file; no code changes needed for new games.
3. **State machine** — `LauncherState` drives UI; invalid transitions are prevented.
4. **Privacy-first logging** — All paths redacted; logs are local-only.
5. **No shell execution** — All processes via `Process.executableURL` + `Process.arguments`.
6. **Fail-closed security** — If a validation gate cannot determine safety, the operation is blocked.
