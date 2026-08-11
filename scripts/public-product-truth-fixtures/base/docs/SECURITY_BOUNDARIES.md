# Security Boundaries — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## Overview

MacSteam enforces security through a series of validation gates. Each gate prevents a specific class of security violations. Gates are evaluated in sequence and are **fail-closed** — if a gate cannot determine safety, the operation is blocked.

---

## 1. ExecutionBoundary

**Purpose:** Constrain what executables can be launched and under what conditions.

### Constraints

| Constraint | Enforcement |
|------------|-------------|
| **Executable location** | Only executables within the prefix or a user-selected recognized runtime are allowed. No arbitrary executables. |
| **Working directory** | Must be set to the prefix drive_c root or a known Steam directory. Never set to system directories. |
| **WINEPREFIX** | Must be set to the canonical prefix path before launching any Wine process. |
| **Environment allow-list** | Only the following environment variables are forwarded: `WINEPREFIX`, `WINEDLLOVERRIDES`, `WINEARCH`, `DISPLAY`, `WAYLAND_DISPLAY`, `HOME`, `USER`, `PATH` (system PATH only, not user-modified). All other variables are stripped. |

### Implementation pattern

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: executablePath)
process.arguments = arguments
process.currentDirectoryURL = workingDirectory
process.environment = ExecutionBoundary.allowedEnvironment(prefix: prefix)
try process.run()
```

### What is prevented

- Running executables outside the prefix boundary.
- Launching arbitrary system commands.
- Executing shell scripts.
- Running setuid binaries.
- Using `NSWorkspace.open` on untrusted files.

---

## 2. PathBoundary

**Purpose:** Prevent path traversal attacks that could read or modify files outside the prefix.

### Validation rules

1. **Normalize** — All paths are normalized (`.`, `..` resolved) before validation.
2. **Baseline check** — Reject any path that, after normalization, does not start with the prefix path.
3. **Component check** — Reject any path with more `..` components than directory depth.
4. **Absolute path check** — Reject any path that after normalization points outside the prefix.
5. **Boundary log** — Record all path validations in the prefix log (with path redaction).

### Examples

| Input | Result | Reason |
|-------|--------|--------|
| `drive_c/Windows/System32/` | ✅ Pass | Inside prefix |
| `drive_c/Program Files/../Windows/` | ✅ Pass | Normalizes to `drive_c/Windows/` |
| `../../../etc/passwd` | ❌ Block | Traversal outside prefix |
| `/Users/Shared/something` | ❌ Block | Absolute path outside prefix |
| Symlink to `/etc` | ❌ Block | Resolved by SymlinkValidator |

---

## 3. SymlinkValidator

**Purpose:** Detect and block symlink escape attacks.

### Detection

Before any file operation within a prefix:

1. Resolve all symlinks in the path components.
2. Compare the resolved path against the prefix boundary.
3. If the resolved path is outside the prefix, block the operation.

```swift
func validateSymlinks(path: String, prefix: String) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let canonicalPrefix = URL(fileURLWithPath: prefix).standardized
    return resolved.path.hasPrefix(canonicalPrefix.path)
}
```

### Additional checks

- The prefix root directory itself must not be a symlink.
- All ancestor directories of the prefix must not be symlinks to unexpected locations.
- Detection runs at prefix creation time and before every destructive operation.
- Symlinks created inside the prefix are allowed only if they point within the prefix.

---

## 4. ArtifactVerifier

**Purpose:** Verify the integrity of downloaded artifacts (future use) using SHA-256.

### Verification flow

```
1. Receive artifact file + expected SHA-256 from manifest
2. Compute SHA-256 of artifact: shasum -a 256 <artifact>
3. Compare computed hash to expected hash
4. If match  → proceed
   If mismatch → reject, delete artifact, log warning
```

### Current U1 status

| Capability | Status |
|------------|--------|
| SHA-256 computation | ✅ Available |
| Manifest parsing | ✅ Available |
| Artifact download | ❌ Not implemented |
| Atomic install | ❌ Not implemented |

The verification logic exists (it is used for verifying non-downloaded files in tests), but the full artifact pipeline (download + verify + activate) is not connected in U1.

---

## 5. No Shell Invocation

**Rule:** MacSteam **never** invokes `/bin/sh -c` or any shell to execute commands.

### Enforced by

- Architecture: `ProcessRunner` uses `Process.executableURL` and `Process.arguments` — raw arrays, not formatted strings.
- Code review: Any use of `Process.run()` with a shell or `bash -c` must be rejected.
- CI: The public audit script (`scripts/public-audit.sh`) scans for shell invocation patterns in Swift files.

### Why

Shell invocation opens the door to:
- Shell injection via crafted arguments.
- Uncontrolled PATH resolution of utilities.
- Environment variable expansion leading to information disclosure.
- Difficulty in composing secure argument arrays.

---

## 6. No Sudo Elevation

**Rule:** MacSteam **never** uses `sudo`, `privileged execution`, or any form of privilege escalation.

### Enforced by

- Code review: Any call to `sudo`, `AuthorizationExecuteWithPrivileges`, or SMJobBless must be rejected.
- Architecture: All operations run in the user's context.
- Principle: MacSteam operates entirely within `~/Library/Application Support/MacSteam/` and has no need for elevated privileges.

---

## 7. No String-Command Concatenation

**Rule:** Commands must be built as structured arrays (`Process.arguments`), not concatenated strings.

### Good

```swift
let process = Process()
process.executableURL = wineURL
process.arguments = [
    prefix.appending("drive_c/.../steam.exe").path,
    "-applaunch",
    "3314790"
]
```

### Bad (forbidden)

```swift
let cmd = "wine64 \(prefix)/drive_c/.../steam.exe -applaunch 3314790"
// String concatenation — forbidden
```

### Why

- String concatenation makes argument boundaries ambiguous.
- Special characters (spaces, quotes, semicolons) in paths or arguments can lead to injection.
- Array-based arguments are unambiguous and safe.

---

## 8. No Arbitrary URL Downloads

**Rule:** MacSteam does not download content from arbitrary URLs.

### What is allowed

- Manifest-signed, verified downloads (future capability — not active in U1).
- Only URLs listed in a signed manifest with SHA-256 verification.

### What is forbidden

- Downloading from user-provided URLs.
- Downloading from URLs embedded in recipes.
- Following redirects to untrusted domains.
- Downloading without SHA-256 verification.

---

## 9. No Credential Output in Logs/Receipts

**Rule:** Credentials, tokens, and secrets must never appear in logs, receipts, crash reports, or diagnostics output.

### Enforced by

- Automated redaction: `PathRedactor` service redacts known credential patterns.
- Receipt format: Destruction receipts contain only metadata — no environment variables, no command arguments, no path content.
- Logging: All paths are redacted to `[REDACTED_PATH]` before logging.
- CI: `scripts/public-audit.sh` scans for credential patterns (GitHub tokens, AWS keys, Slack tokens, authorization headers).

---

## Summary

| Gate | What it prevents | Fail-closed? |
|------|-----------------|:------------:|
| ExecutionBoundary | Arbitrary executable execution | ✅ |
| PathBoundary | Path traversal outside prefix | ✅ |
| SymlinkValidator | Symlink escape attacks | ✅ |
| ArtifactVerifier | Tampered or corrupted artifacts | ✅ (future) |
| No shell | Shell injection | ✅ |
| No sudo | Privilege escalation | ✅ |
| No string concatenation | Argument injection | ✅ |
| No arbitrary downloads | Uncontrolled network access | ✅ |
| No credential output | Secret leakage | ✅ |
