Everything below this canonical block is retained as historical development context and may reference superseded commits, CI runs, intermediate classifications, or earlier pending work.

<!-- macsteam-u1r18-canonical-state:v1 -->
## Canonical U1R18 State

```yaml
repository: oxcandy-lgtm/macsteam
pull_request: 2
branch: feat/ultimate-cloverpit-u1
base_branch: feat/public-oss-bootstrap
head: 90fb379d03ed71bd2c07f73a27f77551a79bee88

pr:
  state: open
  draft: true
  merged: false
  mergeable: true

workstreams:
  R6:
    state: CLOSED
    classification: GREEN_U1R18_R6_AUTONOMOUS_DIAGNOSTIC_BUNDLE_CLOSED

  R5:
    state: EXTERNAL_PROOF_REQUIREMENT_REMOVED
    external_real_mac_proof_performed: false
    external_real_mac_proof_claimed: false

  R4:
    state: CLOSED
    classification: GREEN_U1R18_R4_HOST_PROCESS_LINEAGE_CLOSED

  R3:
    state: CLOSED
    classification: GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED

  R7:
    state: CLOSED
    classification: GREEN_U1R18_R7_CLOSED

review_gate:
  worker_report_comment_id: 5171557506
  submission_run_id: 30851991100
  controller_review_id: 4848480038
  live_review_run_id: 30858402921
  final_state: REVIEW_COMPLETE_NX_REQUIRED
  worker_report_valid: true
  controller_review_valid: true
  nx_required: true
  next_workstream_admitted: false

core_ci:
  run_id: 30851323699
  required_jobs_success: 5

gate_advance:
  run_id: 30851324281
  state: CURRENT_WORKSTREAM_ACTIVE

authorization:
  r8_defined: false
  r8_authorized: false
  ready_authorized: false
  merge_authorized: false
  release_authorized: false
```

R5 external real-Mac proof requirement was removed by product-owner decision. No external proof was performed or claimed.

---
---

## U1R7: Real Session Wiring → CrossOver-Free P2 Hardware Proof

### Completed: P1.5 (all sub-items GREEN)

**ProcessSupervisor + SupervisedProcessHandle**
- `actor ProcessSupervisor` owns all `Process` objects
- `SupervisedProcessHandle` (Sendable, Equatable): UUID/PID/timestamp only
- `launch(plan:)` → `requestTerminate()` → `waitForExit(timeout:)` → `requestForceKill()`

**SessionLock rewrite**
- SHA-256 from canonical (symlink-resolved) path, not `lastPathComponent`
- FD close on lock failure before throwing

```swift
let lock = try SessionLock.acquire(prefix: prefix, runtime: runtime)
defer { lock.release() }
```

**WineServerController async timeout**
- `terminationHandler` + `Task.sleep` race pattern

### P2 (pending — needs user at keyboard)

1. MacsTeam UI → independent Wine runtime → CloverPit launch
2. X-close preserves session (runningHidden)
3. Duplicate launch blocked

---

# U1R10 — Steam CEF Black-Screen Probe Report

## Authority

```yaml
authority:
  head: c49638e45ea37e59e9a5cebc44a86881054e8951
  hosted_ci_run_number: 21
  hosted_ci_run_id: 30449092003
  draft: true
  open: true
  merged: false
```

## Probe Results

| Probe | Profile | Result |
|-------|---------|--------|
| A0 | `.automatic` | Black screen (Steam crash confirmed) |
| A1 | `.cefSoftwareRendering` | Black screen (Steam crash confirmed) |

```
[22:03:53] Step 2: Creating Wine prefix…   ← from createPrefix()
[22:03:55] Step 2: Creating Wine prefix…   ← second call
```

## U1R11 — Steam UI復旧＋Setup導線＋MacsTeam表記統一

### Classification

```yaml
steam_setup_lifecycle:
  back_wired_to_prefix_ready: true
  install_wired_to_coordinator: true

verification:
  swift_build: passed
  swift_test: 181/181 passed
  public_audit: "20/0"
  distribution_gate: "PASS"
  commit: c3c8e03
  working_tree_clean: true
```

### Changes

| File | Change |
|------|--------|
| `SteamSetupView.swift` | Full rewrite |
| `UltimateSetupView.swift` | Delegates steam states |

---

## U1R12 — Settings Profile Picker

### Verification

```
swift build:     ✅
swift test:      187/187 ✅
public-audit:    20/0 ✅
distribution:    PASS ✅
commit:          48824f9
```

---

## U1R13 — Session lifecycle + Standalone WineCX Import

### Changes

| Workstream | Detail |
|------------|--------|
| SessionPurpose | `steamSetup` / `game` enum |
| Recovery by purpose | `steamSetup` → shutdown prefix |
| Tests | +8. Total 195. |

### Current Steam residue

```
PREFIX=.../cloverpit
WINEPREFIX="$PREFIX" wineserver -k && wineserver -w
✅ Complete
```

---

## 過去の補足

旧run 30449092003 と旧commit c49638e45ea37e59e9a5cebc44a86881054e8951 は
R7までの歴史的コンテキストです。canonical blockの置換ではこれらを一切変更しません。

```
historical run id: 30851324281
historical sha: 90fb379d03ed71bd2c07f73a27f77551a79bee88
```

---

