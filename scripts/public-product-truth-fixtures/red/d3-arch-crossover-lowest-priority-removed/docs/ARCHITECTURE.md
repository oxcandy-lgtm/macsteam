# Architecture

## Overview

MacSteam is a macOS application built with SwiftUI that selects a compatible
runtime, creates/manages a canonical Wine prefix, drives Steam through a
user-selected installer, and launches Windows games — starting with CloverPit.
Imported Wine is the canonical U1 runtime; CrossOver is only a disabled-by-default,
explicit opt-in commercial adapter, never a prerequisite.

```
┌──────────────────────────────────────────────┐
│                  SwiftUI                      │
│  LauncherView / DiagnosticsView              │
└──────────────────┬───────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│                GameManager                    │
│  ┌───────────┐ ┌──────────┐ ┌──────────────┐│
│  │RecipeLoader│ │Runtime   │ │SteamDetector  ││
│  │           │ │Registry  │ │              ││
│  └───────────┘ └──────────┘ └──────────────┘│
│  ┌───────────┐ ┌──────────┐                │
│  │Diagnostics│ │Process   │                │
│  │Store      │ │Runner    │                │
│  └───────────┘ └──────────┘                │
└──────────────────┬───────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│           CompatibilityRuntime                │
│  ┌────────────────┐  ┌──────────────────────┐│
│  │ImportedWineRuntime│  │   SystemWineRuntime ││
│  └────────────────┘  └──────────────────────┘│
│  ┌────────────────┐                          │
│  │ CrossOverRuntime│  (disabled-by-default,  ││
│  └────────────────┘   explicit opt-in only)  ││
│  ┌────────────────┐                          │
│  │  ManagedWine   │  (future)                ││
│  └────────────────┘                          ││
└──────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. Protocol-Oriented Runtime Abstraction

`CompatibilityRuntime` protocol allows adding new runtimes without changing
GameManager, UI, or recipes.

### 2. Recipe-Driven Game Definitions

Games are defined by JSON recipes, not code. A recipe specifies:
- Store type and App ID
- Preferred runtime adapter
- Launch arguments
- Detection criteria

### 3. State Machine

`LauncherState` drives the UI. Every state has a clear user-facing message
and possible actions. Invalid transitions are prevented.

### 4. Privacy-First Logging

All paths are redacted before logging. Logs are local-only.

### 5. No Shell Execution

All processes are launched with `Process.executableURL` and `Process.arguments`.
`/bin/sh -c` is never used.
