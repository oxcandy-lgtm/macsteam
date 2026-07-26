# Source Offer Policy — GPL Compliance

> **Version:** 1.0  
> **Applies to:** MacSteam Ultimate (cloverpit-u1)  
> **GPL provision:** GPL-3.0-or-later, §6 ("Corresponding Source")

## 1. Purpose

The GNU General Public License v3.0 or later requires that any distribution of GPL-licensed binaries be accompanied by a written offer for Corresponding Source. This document describes how MacSteam fulfills that obligation.

---

## 2. Source Code Availability (Primary Method)

MacSteam's complete Corresponding Source is publicly available at:

- **Repository:** [https://github.com/macsteam/macsteam](https://github.com/macsteam/macsteam)
- **Default branch:** `main`
- **Release tags:** Each release is tagged with a version number matching the binary release (e.g., `v1.0.0`).

The repository contains:

- All MacSteam-authored source files
- Build scripts and CMake/Xcode project files
- Scripts used to produce binary artifacts
- The complete revision history (git log)

Source code published on GitHub satisfies the GPL requirement to "give the recipient access to the Corresponding Source" for at least three years after the last distribution of the covered work.

---

## 3. Written Offer (Binary Distributions)

When MacSteam is distributed as a binary (`.app` bundle, DMG installer, or via a package manager), the distribution **must** include or accompany a written offer.

### Standard Offer Text

Include the following in a `SOURCE_OFFER.txt` file at the root of any binary distribution:

```
SOURCE CODE OFFER

This software is released under the GNU General Public License v3.0 or later
(GPL-3.0-or-later).

You may obtain the complete Corresponding Source code for this release at:

    https://github.com/macsteam/macsteam

To obtain the exact source corresponding to this binary release:

  1. Visit the URL above.
  2. Check out the tag matching this release's version number.
  3. See BUILD.md for build instructions.

Alternatively, you may send a written request to the project maintainers.
We will provide the Corresponding Source on a durable physical medium or by
other means customary for inter-machine communication, for a charge no more
than the cost of physically performing source distribution.

A copy of the GNU General Public License v3.0 is included in this distribution
as COPYING.txt.
```

### Placement

| Distribution type | Location |
|---|---|
| `.app` bundle | `MacSteam.app/Contents/Resources/SOURCE_OFFER.txt` |
| DMG installer | Root of the DMG volume |
| Package manager feed | Linked in formula/recipe metadata |
| Source archive (tarball) | Not required (source is the offer itself) |

---

## 4. How to Obtain Exact Source for a Release

1. Determine the release version (e.g., `v1.0.0`) — this is printed on the "About MacSteam" screen and in `--version` output.
2. Clone the repository (if you do not already have it):
   ```
   git clone https://github.com/macsteam/macsteam.git
   ```
3. Check out the release tag:
   ```
   git checkout v1.0.0
   ```
4. Optionally verify the tag signature (if tags are signed):
   ```
   git tag -v v1.0.0
   ```

The tree at that tag **is** the Corresponding Source for that binary release.

---

## 5. Build Instructions Reference

Detailed build instructions are maintained in the repository at:

- **`BUILD.md`** — Full build guide covering all platforms.
- **`BUILD_QUICKSTART.md`** — Abbreviated version for experienced developers.
- **`Dockerfile`** — Reproducible build environment (when present).

These documents cover:

- Required toolchain (Xcode version, CMake, Ninja, etc.)
- Dependency installation
- Build flags and configuration options
- Signing and notarization steps for macOS
- How to produce a distributable `.app` bundle

---

## 6. Future Provision: Written Request

When MacSteam begins distributing binaries outside the GitHub Releases mechanism (e.g., a dedicated download site or auto-updater), the following address will accept written requests for Corresponding Source:

```
MacSteam Project
[Contact address TBD]
```

Requests will be fulfilled within a reasonable time (typically 14 days) at a nominal cost not exceeding the physical cost of distribution.

---

## 7. Compliance Checklist

Before any binary distribution ships, confirm:

- [ ] GitHub repository is public and contains the correct release tag.
- [ ] `SOURCE_OFFER.txt` is bundled in the distribution artifact.
- [ ] `COPYING.txt` (full GPL-3.0-or-later text) is bundled in the distribution artifact.
- [ ] Build instructions are up to date in `BUILD.md`.
- [ ] The release tag in git matches the binary version string.
- [ ] Any GPL-licensed third-party libraries have their own source offers satisfied.

---

*Questions about GPL compliance should be directed to the MacSteam project maintainers.*
