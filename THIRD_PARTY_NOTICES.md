# Third-Party Notices

MacSteam itself is licensed under GPL-3.0-or-later.

This project does not bundle, include, or redistribute any third-party
binaries, libraries, game assets, or proprietary components.

All third-party software referenced by or used with MacSteam must be
obtained by the user from its official provider.

## Component Registry

Third-party components are tracked in
[`Sources/MacSteam/Resources/Legal/component-lock.json`](Sources/MacSteam/Resources/Legal/component-lock.json).

| Component | License | Bundled | Redistribution |
|-----------|---------|---------|----------------|
| Wine | LGPL-2.1-or-later | No | Review required |
| DXVK-macOS | Zlib | No | Review required |
| MoltenVK | Apache-2.0 | No | Review required |
| Steam Client | Proprietary (Valve) | No | Forbidden |
| D3DMetal | Proprietary (Apple) | No | Forbidden until reviewed |

## Binary Distribution Policy

MacSteam does not distribute:

- **Steam Client** — user-obtained via Valve official page only
- **Wine binaries** — future distribution requires exact upstream commit,
  license, corresponding source, patchset, build script, SHA-256, and SBOM
- **CloverPit** — user-obtained via Steam store, never bundled
- **DXVK-macOS / MoltenVK** — adapter contracts only in U1, no binaries
- **Apple Game Porting Toolkit / D3DMetal** — never bundled
- **Microsoft DLLs, fonts, or redistributables** — not in U1
- **Game assets, logos, screenshots** — never included

## Source Code

MacSteam source: https://github.com/oxcandy-lgtm/macsteam

## Trademarks

- **Steam** is a trademark and/or registered trademark of Valve Corporation.
- **CrossOver** is a trademark of CodeWeavers.
- **CloverPit** is a trademark of its respective publisher.
- **Apple**, **macOS**, and **Apple Silicon** are trademarks of Apple Inc.
- **Wine** is a trademark of the Wine Project.
- **MoltenVK** is a trademark of The Brenwill Workshop Ltd.
- **Vulkan** and **Vulkan logo** are trademarks of the Khronos Group Inc.

All other trademarks and product names belong to their respective owners.

---

*If you believe a dependency has been omitted, please open an issue.*
