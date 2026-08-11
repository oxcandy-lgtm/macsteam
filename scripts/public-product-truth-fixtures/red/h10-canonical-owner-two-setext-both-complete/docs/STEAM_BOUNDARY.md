# Steam Integration Boundary — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## 1. Overview

MacSteam integrates with Steam to launch Windows games purchased on the Steam platform. This integration is **strictly bounded** — MacSteam does not redistribute Steam, access credentials, or automate account actions.

---

2. Steam Installer: User-Selected File Only
-------------------------------------------


MacSteam **never** bundles or downloads the Steam installer. The user must obtain the Steam installer `.exe` independently.

### How Steam is provided to MacSteam

Only one method is supported in U1:

| Method | Description | Supported? |
|--------|-------------|------------|
| **User-selected file** | User navigates to the Steam installer `.exe` (e.g., SteamSetup.exe) | ✅ Yes |
| Automatic detection | MacSteam scans standard locations for Steam | ✅ Yes (when present) |
| Bundled installer | SteamSetup.exe included in MacSteam | ❌ Never |
| Download from Valve | MacSteam downloads Steam on user's behalf | ❌ Never |

### Verification checks

When the user selects a Steam installer `.exe`, MacSteam verifies:

1. The selected path is a **regular file** (not a directory or special file).
2. The file is a `.exe` executable.
3. The file is **non-empty**.
4. The file's **SHA-256** is recorded as evidence for the run.
5. The path does not contain traversal components (PathBoundary).

`InstallerSupervisor` runs the selected installer inside the canonical prefix with the selected runtime and supervises it.

MacSteam does **not** bundle, download, or redistribute the Steam installer, and does **not** install Steam on the user's behalf beyond executing the user-selected installer inside the prefix.

---

2. Steam Installer: User-Selected File Only
-------------------------------------------


MacSteam **never** bundles or downloads the Steam installer. The user must obtain the Steam installer `.exe` independently.


## 3. No Credential Access

MacSteam **never**:

- Reads, stores, or transmits Steam credentials (username, password, login key, session tokens).
- Interacts with Steam's authentication API.
- Modifies Steam's configuration files related to accounts.
- Reads `loginusers.vdf` or any account-related files.
- Hooks or injects into the Steam process.

The user's Steam authentication is handled entirely by Steam itself within the Wine prefix.

---

## 4. No Automatic Login

MacSteam **never**:

- Attempts to auto-login to Steam.
- Remembers Steam login state.
- Sends keystrokes or mouse events to the Steam login window.

The user must log into Steam manually (once per prefix), and Steam's "Remember me" feature persists the session within the prefix as normal.

---

## 5. No SSA Acceptance

MacSteam **never**:

- Accepts the Steam Subscriber Agreement (SSA) on behalf of the user.
- Modifies Steam's agreement acceptance state.
- Bypasses any Steam UI that requires user interaction.

SSA acceptance is a personal legal act and must always be performed by the human user.

---

## 6. Steam Startup Sequence

```
1. WINEPREFIX is set to the game's prefix directory.
2. Working directory is set to the Steam installation directory.
3. ProcessRunner creates:
   executable = <wine runtime executable>
   arguments  = ["<steam.exe path>", "-applaunch", "<appid>", ...]
   environment = {
       "WINEPREFIX": "<prefix-path>",
       ... (allow-listed env vars only)
   }
4. Process is launched (no shell, no sudo).
5. Steam UI appears in the Wine window.
6. If game is installed, it launches automatically.
7. If game is not installed, Steam shows the game page for installation.
```

### Process creation constraints

- Must use `Process.executableURL` and `Process.arguments` array.
- Environment variables must come from the allow-list.
- Must not use `Process.standardInput` to send data.
- Must not use `/bin/sh -c` or any shell wrapper.
- Must not use `sudo` or privilege escalation.

---

## 7. Detection

### Steam installation detection

MacSteam scans for Steam at these paths:

| Priority | Path |
|----------|------|
| 1 | User-selected file path |
| 2 | `~/Library/Application Support/Steam/` |
| 3 | `/Applications/Steam.app/` |

### Game installation detection

MacSteam detects a game as installed by the presence of the `.acf` manifest:

```swift
// appmanifest_*.acf presence check (planned: value parsing)
func detectGame(appId: String) -> Bool {
    let manifestPath = steamPath
        .appending("steamapps")
        .appending("appmanifest_\(appId).acf")
    return FileManager.default.fileExists(atPath: manifestPath.path)
}
```

Planned (not yet asserted as implemented): parsing of `.acf` values such as `"installdir"`, `"StateFlags"`, and `"buildid"`.

MacSteam reads `.acf` files only for detection purposes — it **never** modifies them.

---

## 8. Logging

When logging Steam-related operations:

- Steam installation path is **redacted** before logging (replaced with `[STEAM_PATH]`).
- No account identifiers are logged.
- No game library contents beyond the target app ID are logged.
- `.acf` file contents are not logged verbatim — only detection results (installed/not installed).

See [SECURITY_BOUNDARIES.md](./SECURITY_BOUNDARIES.md) for the full security model.
