# MacSteam

**An independent open-source compatibility launcher for macOS.**

MacSteam detects your existing CrossOver installation and lets you launch
Windows Steam games — starting with **CloverPit** — from a native macOS UI.

> MacSteam is not affiliated with, endorsed by, sponsored by, or licensed by
> Valve Corporation, CodeWeavers, Apple, or any supported game developer
> or publisher.
>
> MacSteam does not include or distribute Steam, CrossOver, Wine,
> Apple Game Porting Toolkit, or any supported game.
>
> Steam is a trademark and/or registered trademark of Valve Corporation.
> All other product names belong to their respective owners.

---

## Current Status

| Aspect | Status |
|---|---|
| Platform | macOS (Apple Silicon) |
| Language | Swift 6 |
| UI | SwiftUI |
| Initial runtime | CrossOver |
| Initial store | Windows Steam |
| Initial game | CloverPit (App 3314790) |
| License | GPL-3.0-or-later |

### Compatibility

| Game | Status |
|---|---|
| CloverPit | Experimental — launch command constructed |

## Prerequisites

- macOS Sequoia 15.0+ (Apple Silicon)
- [CrossOver](https://www.codeweavers.com/crossover) installed
- Windows Steam installed inside CrossOver
- CloverPit purchased and installed via Windows Steam

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

Or open the package in Xcode and run from there.

## Test

```bash
swift test
```

Tests cover all core components with zero external dependencies.

## How It Works

```
MacSteam → GameManager → RuntimeLocator → CrossOverRuntime
                        → SteamDetector  → Windows Steam
                        → ProcessRunner  → Game launch
```

1. **Recipe loading**: Reads game configuration from `Resources/Recipes/`
2. **Runtime detection**: Locates CrossOver.app and validates it
3. **Steam detection**: Distinguishes macOS Steam from Windows Steam
4. **Game inspection**: Checks for manifest, install directory, and executable
5. **Launch**: Runs Steam with the game's app ID arguments

## Privacy

MacSteam does not collect telemetry, analytics, or personal data.
All diagnostics stay local. See [PRIVACY.md](PRIVACY.md).

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Known Limitations

- Only CloverPit is supported in the initial release
- CrossOver internal paths are approximated and may need adjustment
- No Wine or Whisky runtime support yet
- No game image or metadata display
- No save management or cloud sync

## Roadmap

- [x] Public OSS bootstrap
- [ ] Additional game recipes
- [ ] Wine runtime support
- [ ] Multi-game library UI
- [ ] Game image/metadata display
- [ ] Bottle management

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
