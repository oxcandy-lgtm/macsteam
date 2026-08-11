# Prefix Lifecycle — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## 1. Location

All game prefixes are stored under:

```
~/Library/Application Support/MacSteam/Prefixes/<game-id>/
```

Where `<game-id>` matches the recipe `id` field (e.g., `cloverpit`).

### Directory structure

```
<game-id>/
├── prefix/              # The Wine prefix (drive_c, etc.)
├── metadata/            # Recipe, runtime info, timestamps
│   ├── recipe.json      # Copy of the game recipe
│   ├── runtime.json     # Selected runtime info
│   ├── created.json     # Creation timestamp + wineboot log hash
│   └── state.json       # Current prefix state
├── snapshots/           # Prefix snapshots (future use)
│   └── <timestamp>.tar.gz
├── logs/                # Per-session logs
│   └── <timestamp>.log
└── user-overlay/        # User modifications overlay
    ├── registry/        # User registry overrides
    └── files/           # User file overrides
```

---

## 2. Creation

### Flow

```
1. Create empty prefix directory
2. Set WINEPREFIX to prefix path
3. Run: wineboot -u          (init prefix)
   → Creates drive_c, system registry, default config
4. Apply recipe operations:
   a. Set Windows version
   b. Install Wine components
   c. Set recipe registry keys
5. Validate prefix structure
6. Write metadata files
```

### Validation after creation

- Check `drive_c/` exists
- Check system registry files exist (`system.reg`, `user.reg`, `userdef.reg`)
- Verify `wineboot` exited with code 0
- Record `wineboot` log hash in `metadata/created.json`

---

## 3. Destruction Safety Rules

Prefix destruction is a high-risk operation. The following safety checks must pass before any destructive action:

### Rule 1 — Canonical Path Check

```
if realpath(prefix_dir) != prefix_dir:
    FAIL("Prefix path is not canonical")
```

Prevents operations on symlinked or aliased directories.

### Rule 2 — Symlink Check

```
if is_symlink(prefix_dir):
    FAIL("Prefix path is a symlink")
```

Prevents following a symlink to an unexpected location.

### Rule 3 — Active Process Check

```
if process_running_within_prefix(prefix_dir):
    FAIL("Active process running in prefix")
```

Prevents destruction while a game or Wine process is using the prefix.

### Rule 4 — Save Discovery

```
saves = discover_saves(prefix_dir)
if len(saves) > 0:
    inform_user(saves)
    require_confirmation()
```

Before destruction, discover any save files and inform the user.

### Rule 5 — Backup

```
backup_path = backup_prefix(prefix_dir)
if not backup_path:
    FAIL("Backup failed")
```

Create a backup (rsync/snapshot) before any destructive operation.

### Rule 6 — User Confirmation

```
if not user_confirmed("Destroy prefix at {path}?"):
    CANCEL("User cancelled")
```

Explicit confirmation dialog with the full canonical path displayed.

### Rule 7 — Receipt

```
receipt = {
    "action": "destroy",
    "prefix": "<game-id>",
    "path": "<canonical-path>",
    "timestamp": "<iso-8601>",
    "backup_path": "<backup-location>",
    "user_confirmed": true,
    "saves_backed_up": <count>
}
write_receipt(receipt)
```

Every destruction must produce a receipt for audit.

---

## 4. U1 Constraints

| Feature | U1 Status |
|---------|-----------|
| Prefix creation | ✅ Full support |
| Prefix detection | ✅ Full support |
| Prefix destruction | ❌ **Dry-run only** — all checks run, but no actual destruction |
| Save discovery | ✅ Discover-only mode |
| Save backup | ✅ Backup created, no restore in U1 |
| Snapshots | 📋 Designed, not implemented |
| User overlay | 📋 Designed, not implemented |

### Destructive repair disabled

In U1, the `backupBeforeDestructiveRepair` field in `savePolicy` is set to `false` for all recipes, and the destruction path code **never executes** the actual `rm -rf` or equivalent — it only runs the safety checks and reports what would be destroyed.

This will be activated in a future release after the full destruction pipeline has been audited.
