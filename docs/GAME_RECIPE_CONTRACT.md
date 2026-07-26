# Game Recipe Contract — MacSteam

> **Version:** 2.0
> **Schema:** `Contracts/game-recipe.schema.json` (v2)
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## 1. Schema v2 Fields and Constraints

Every game recipe is a JSON object conforming to `Contracts/game-recipe.schema.json`.

### Required fields

| Field | Type | Constraint |
|-------|------|------------|
| `schemaVersion` | `const: 2` | Must be exactly `2` |
| `id` | string | Unique recipe identifier (kebab-case, e.g. `cloverpit`) |
| `displayName` | string | Human-readable game name |
| `store` | object | `{ type: string, appId: string }` — no additional properties |
| `runtime` | object | `{ requiredCapabilities, preferredRuntime, fallbackRuntimes }` |
| `graphics` | object | `{ preferred, fallback }` |
| `prefix` | object | `{ id, windowsVersion, isolation }` |
| `storeInstallation` | object | `{ installerMode, installerProduct, redistribution }` |
| `launch` | object | `{ storeArguments: string[] }` |
| `detection` | object | `{ manifestName, executableCandidates }` |
| `savePolicy` | object | `{ mode, backupBeforeDestructiveRepair }` |

### Validation rules

- `schemaVersion` **must** be `2` (enforced by `const`).
- `store.type` — currently supports `"steam"`.
- `runtime.requiredCapabilities` items must be from the allow-listed set.
- `runtime.preferredRuntime` and `runtime.fallbackRuntimes` must reference known adapter types.
- `storeInstallation.redistribution` must be `"forbidden"` for games not owned by MacSteam.
- `detection.executableCandidates` — list of candidate executable filenames.
- `savePolicy.mode` — one of `"discover-only"`, `"backup-enabled"`, `"full-managed"`.

---

## 2. What Recipes Must NOT Contain

Recipes are **declarative only**. The following content is **strictly forbidden**:

| Forbidden | Reason |
|-----------|--------|
| Shell commands (`runShell`) | Opens arbitrary execution surface |
| Sudo invocation (`runSudo`) | Privilege escalation |
| Arbitrary URLs (`downloadArbitraryURL`) | Uncontrolled download source |
| Absolute host paths (`/Users/...`, `/tmp/...`) | Path traversal risk |
| Credentials | Secret leakage |
| Environment variable expansion in path strings | Injection risk |
| Base64-encoded payloads | Obfuscation |
| Shell metacharacters in argument strings | Injection risk |

The CI pipeline **enforces** these constraints with automated checks:

```yaml
forbidden = ['runShell', 'runSudo', 'downloadArbitraryURL', 'deleteHostPath']
for op in forbidden:
    assert op not in text, f'Forbidden operation {op} found'
```

---

## 3. RecipeOperation DSL

Recipes use a restricted DSL for describing prefix setup operations. Each operation is an object with a `type` field.

### Allow-listed operations

| Operation type | Purpose | Example |
|---------------|---------|---------|
| `setWindowsVersion` | Set prefix Windows version | `{ "type": "setWindowsVersion", "version": "win10" }` |
| `installComponent` | Install a Wine component | `{ "type": "installComponent", "component": "steam" }` |
| `setRegistryKey` | Set a registry key/value | `{ "type": "setRegistryKey", "key": "...", "value": "..." }` |
| `runInstaller` | Run a known installer in prefix | `{ "type": "runInstaller", "executable": "setup.exe", "args": [...] }` |
| `copyFile` | Copy file within prefix | `{ "type": "copyFile", "source": "...", "destination": "..." }` |
| `deletePrefixFile` | Delete file inside prefix | `{ "type": "deletePrefixFile", "path": "..." }` |

### Operation constraints

- All paths are relative to the prefix root.
- `runInstaller` executable must be a known allow-listed filename.
- `copyFile` source must be within the store installation directory.
- `deletePrefixFile` path must be within the prefix and validated by PathBoundary.

---

## 4. Security Validation

### DistributionGate

Evaluated at recipe load time:

1. Check `storeInstallation.redistribution` — if `"forbidden"`, prevent any redistribution.
2. Check that no forbidden components are referenced.
3. Verify that the game's store type is supported.

### PathBoundary

Every path in a recipe passes through PathBoundary validation:

- Rejects absolute paths outside the prefix boundary.
- Rejects paths with `..` traversal beyond the prefix.
- Rejects symlinks that escape the prefix (checked at resolution time).
- All paths are normalized before use.

### Fail-closed behavior

If any validation gate cannot determine safety (e.g., a path cannot be resolved), the operation **must** be blocked. "Maybe safe" is treated as "not safe."
