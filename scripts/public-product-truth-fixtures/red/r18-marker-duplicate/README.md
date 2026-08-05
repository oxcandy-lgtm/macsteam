# MacsTeam

<!-- macsteam-public-product-truth:v1 -->

**An independent GPL-3.0-or-later macOS compatibility launcher for Windows
Steam games — starting with CloverPit.**

MacsTeam is the public display name. The internal Swift module and the
repository history use `MacSteam`. This README describes the product that
exists at this repository HEAD; see [docs/public-product-truth.json](docs/public-product-truth.json)
for the machine-readable authority and the [public product truth audit](scripts/public-product-truth-audit.py)
for the fail-closed checks that keep this documentation honest.

> MacsTeam is not affiliated with, endorsed by, sponsored by, or licensed by
> Valve Corporation, CodeWeavers, Apple, or any supported game developer
> or publisher.
>
> MacsTeam does not include or distribute Steam, CrossOver, Wine, Apple Game
> Porting Toolkit, or any supported game.
>
> Steam is a trademark and/or registered trademark of Valve Corporation.
> All other product names belong to their respective owners.

---

## Current Status

| Aspect | Status |
|---|---|
| Platform | macOS 15.0+ (Apple Silicon) |
| Language | Swift 6 |
| UI | SwiftUI |
| Product | Development build (Swift Package) |
| CloverPit integration | Implemented |
| Local end-to-end playability acceptance | Pending |
| Downloadable signed/notarized app | Not yet available |

### Compatibility

| Game | Status |
|---|---|
| CloverPit (Steam App 3314790) | Implemented — local acceptance pending |

## Runtime Truth

- **Imported Wine** is the canonical U1 runtime. The user selects a Wine
  directory; MacsTeam validates and uses it.
- System Wine may be discovered, but it is excluded from the default U1 Steam
  runtime selection.
- Managed Wine (downloaded and managed by MacsTeam) is future/unavailable.
- **CrossOver is not required and is not canonical.** CrossOver may exist only
  as a disabled-by-default, explicit opt-in, lowest-priority commercial
  compatibility option. It is never a prerequisite.

## Setup Flow

MacsTeam walks through a coordinator-driven setup:

1. Select/import a runtime.
2. Inspect/create a canonical Wine prefix.
3. Select a user-obtained Steam installer.
4. Install/open Steam.
5. Detect/install/launch CloverPit.

## Build

```bash
git clone https://github.com/oxcandy-lgtm/macsteam.git
cd macsteam
swift build
```

## Run

```bash
swift run
```

Or open the package in Xcode and run from there. This is the current run path:
Swift Package development execution. There is no `.app` bundle release yet.

## Test

```bash
swift test
```

Tests cover the core components with zero external dependencies.

## How It Works

```
MacsTeam → GameManager → RuntimeLocator → ImportedWineRuntime
                        → SteamDetector  → Windows Steam
                        → ProcessRunner  → Game launch
```

1. **Recipe loading**: Reads game configuration from `Resources/Recipes/`
2. **Runtime detection**: Resolves the user-selected/imported runtime and
   validates it
3. **Steam detection**: Distinguishes macOS Steam from Windows Steam
4. **Game inspection**: Checks for manifest, install directory, and executable
5. **Launch**: Runs Steam with the game's app ID arguments

## Distribution Truth

- The current run path is Swift Package development execution through
  `swift run` or Xcode.
- `.app` bundle work is not complete.
- Codesign, notarization, and packaging work are not complete.
- No release download is advertised.

## Safety and Privacy

- No Steam installer bundling.
- No app-controlled Steam installer download.
- No Steam credential access.
- No sudo.
- No shell command construction (launches use argument arrays).
- Diagnostics remain local and redacted.

## Known Limitations

- Actual Steam rendering and CloverPit gameplay acceptance remain pending.
- No performance, FPS, audio, or input claims are made.
- No clean-install or Gatekeeper acceptance claim is made.
- Only CloverPit is the current target.
- No game image/metadata display, save management, or cloud sync yet.

## Completion Roadmap

These are planning-only paths. Neither is authorized or complete.

**Minimal:**
public truth → local runtime acceptance → final audit / Ready / Merge

**General distribution:**
public truth → `.app` build → signing / notarization / packaging →
local runtime acceptance → clean-install / Gatekeeper acceptance →
final audit / Ready / Merge / Release

## R5 Note

R5 external real-Mac proof requirement was removed by product-owner
decision. No external proof was performed or claimed.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
<!-- macsteam-public-product-truth:v1 -->
