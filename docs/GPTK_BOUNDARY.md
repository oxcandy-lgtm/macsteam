# Apple GPTK / D3DMetal Boundary — MacSteam

> **Version:** 1.0
> **Applies to:** MacSteam Ultimate (cloverpit-u1)

## 1. Overview

The **Apple Game Porting Toolkit (GPTK)** and its **D3DMetal** translation layer are proprietary components of Apple Inc. This document defines the boundary for how MacSteam relates to these components.

**Policy summary:** No redistribution. User-obtained only. Future detection adapter design only.

---

## 2. No Redistribution

| Aspect | Detail |
|--------|--------|
| **License** | Proprietary / Apple SDK Agreement |
| **Redistribution** | **Forbidden** |
| **component-lock** | `d3dmetal` registered with `redistribution: "forbidden-until-reviewed"` |
| **Bundle** | ❌ Never bundled in any MacSteam distribution artifact |

> ⚠️ The Apple SDK Agreement and Xcode license restrict redistribution of GPTK and D3DMetal. MacSteam respects these restrictions fully and does not challenge or circumvent them.

---

## 3. User-Obtained Only

GPTK / D3DMetal can only be obtained by the user through official Apple channels:

| Method | Status |
|--------|--------|
| Included in macOS (future) | TBD — Apple's decision |
| Downloaded from Apple Developer | ✅ Official channel |
| Xcode command line tools | ✅ May include D3DMetal |
| Bundled with MacSteam | ❌ Forbidden |
| Downloaded by MacSteam | ❌ Forbidden |
| Third-party redistribution | ❌ Forbidden |

---

## 4. Future Detection Adapter Design (Only)

A future version of MacSteam may include a **detection-only adapter** that checks whether D3DMetal is present on the system. This adapter would:

### What it would do (design sketch)

```swift
protocol D3DMetalDetection {
    var isAvailable: Bool { get }
    var dylibPath: String? { get }
}

class D3DMetalDetector {
    func detect() -> Bool {
        // Check for D3DMetal.framework at standard macOS locations
        // Check for libD3DMetal.dylib available through dyld
        // Return true/false — no files are loaded or copied
    }
}
```

### What it would NOT do

- ❌ Load, copy, or link D3DMetal binaries.
- ❌ Download or stage D3DMetal from any source.
- ❌ Bypass Apple's licensing or terms.
- ❌ Guide users on how to obtain D3DMetal outside Apple's official channels.
- ❌ Bundle detection results in distribution artifacts.

> **This adapter is design-only in U1.** No code implementing D3DMetal detection exists in the U1 codebase.

---

## 5. Fail-Closed Until Explicit Redistribution Confirmation

D3DMetal and GPTK are **fail-closed**:

1. **Cannot be bundled** — Any attempt to add D3DMetal binaries to the repository is blocked by `scripts/distribution-gate.sh`.
2. **Cannot be automatically detected** — The detection adapter does not exist in U1.
3. **Cannot be referenced in recipes** — No D3DMetal capability is defined for recipes.
4. **Cannot be redistributed** — `component-lock.json` explicitly marks D3DMetal as `"forbidden-until-reviewed"`.

### Path to activation

For D3DMetal/GPTK integration to be activated in a future release:

1. Legal review must confirm redistribution terms (or confirm that detection without bundling is permissible).
2. `component-lock.json` entry updated from `"forbidden-until-reviewed"` to an appropriate state.
3. Detection adapter implemented and audited.
4. CI distribution gate updated to allow the new detection mechanism (but still block binary bundling).
5. Recipe system extended with D3DMetal capability.

> None of these steps are complete or in progress for U1.

---

## 6. CI Enforcement

The distribution gate (`scripts/distribution-gate.sh`) explicitly checks for D3DMetal binaries:

```bash
# Check no D3DMetal binaries
if find . -name "libD3DMetal*.dylib" -o -name "D3DMetal.framework" 2>/dev/null | grep -q .; then
  echo "FAIL: D3DMetal binary found"
  exit 1
fi
```

This check runs in CI and must pass for any PR to merge.
