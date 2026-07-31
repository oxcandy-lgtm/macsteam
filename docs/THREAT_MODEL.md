# Threat Model

## Scope

Threat model for MacSteam v0.1.0 — local-only compatibility launcher.

## Assets

| Asset | Description |
|-------|-------------|
| User's game library | Steam game installation metadata |
| User's local configuration | Runtime paths, user preferences |
| Log data | Diagnostics logs (local only) |

## Trust Boundaries

```
[User] → [MacSteam GUI] → [ProcessRunner]
                              ↓
                    [CrossOver / Steam / Game]
```

- MacSteam does not communicate over the network.
- All external processes are launched by the user's explicit action.
- MacSteam reads but does not modify external software.

## Threats

### T1: Process injection via malicious recipe

If a crafted `GameRecipe` JSON contains shell metacharacters or absolute paths
to malicious binaries:

- **Mitigation**: `ProcessRunner` uses `executableURL` + `arguments` (no shell).
  Arguments are never concatenated into a shell string.
- **Mitigation**: Recipe validation rejects absolute paths.
- **Mitigation**: `ProcessRunner` verifies the executable is a regular file before launch.

### T2: Privacy leak via logs

If log output includes real user paths, tokens, or emails:

- **Mitigation**: `PathRedactor` transforms `$HOME` paths before logging.
- **Mitigation**: `DiagnosticsStore` logs only permitted fields.
- **Mitigation**: Logs stay local; there is no upload mechanism.

### T3: Unintended CrossOver/Steam launch at startup

- **Mitigation**: MacSteam never launches external processes automatically.
  Only user-initiated button clicks trigger process execution.
- **Mitigation**: State transitions are guarded against concurrent launches.

### T4: Fake bundle posing as CrossOver

- **Mitigation**: `RuntimeLocator` verifies bundle identifier and required
  executable presence, not just filename.
- **Mitigation**: Detected-but-invalid runtimes report `RUNTIME_INVALID`.

### T5: Game manifest manipulated

- **Mitigation**: `SteamDetector` requires manifest + install directory +
  game executable, not just manifest presence.

## Out of Scope

- Steam or CrossOver network communications
- Game anti-cheat mechanisms
- DRM systems
- Malicious game executables (MacSteam does not verify game integrity)
