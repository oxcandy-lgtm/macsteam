# MacsTeam AI Terminal Control Plane — Canonical Roadmap

## Why this PR exists

The bottleneck is no longer "can CloverPit run on a Mac?" CloverPit has already been launched successfully through CrossOver.

The real problem is operator burden: when MacsTeam stops on a small error, the user currently has to inspect the GUI, explain what is visible, choose the next action, and repeat. That defeats the point of using an AI-driven development/operator loop.

This PR exists to make MacsTeam transparent and operable from the terminal so an AI can read the application, understand exactly where it stopped, read the error, take the next production action, and continue end-to-end without asking the user to supervise every screen.

## Non-negotiable operating rules

1. **Speed and working behavior come first.** If it works, move on. Do not spend separate turns proving already-observed facts.
2. **Proof turns: 0.** Do not create a new validation/review/acceptance turn after every small change. Build the control plane in a few implementation passes, then run one final smoke.
3. **Do not burn context on redundant verification.** Avoid long repeated CI/gate/evidence cycles while this PR is under construction.
4. **Parallelize independent implementation work.** State mirror, event logging, CLI actions, installer observability, and diagnostics should be built in parallel where practical.
5. **The user must not be the step-by-step debugger.** Human involvement is reserved for genuinely human-only interactions such as account authentication or visual judgment that cannot yet be represented by an existing application flag.
6. **Existing proven observations are reusable.** Do not re-prove that a known screen/window can render merely to satisfy process ceremony. Convert the observable into a machine-readable flag and consume it.
7. **Errors are for the AI to read.** Error logs must be structured enough that the AI can identify the failing subsystem, current state, attempted action, expected state, actual state, and likely blocker without asking the user to interpret the GUI.
8. **No duplicated product logic.** SwiftUI and terminal control must call the same production coordinator/intents. The CLI is another frontend, not a second implementation.
9. **Prefer terminal-first plumbing when GUI plumbing adds friction.** Installer state, progress, messages, and actions should be exposed directly to the terminal. If a terminal-first installer path is simpler, use it while preserving the same underlying production engine.
10. **This is intentionally a small project.** The control plane should be completed in a few substantial implementation steps, not stretched into another month of micro-workstreams.

## What must become visible from the terminal

A single machine-readable state snapshot must expose at least:

- current screen / current setup step
- coordinator state
- selected runtime and whether the real runtime loaded
- canonical prefix state
- Steam executable presence
- Steam lifecycle / readiness
- whether Windows Steam is running
- whether the expected Steam window is visible
- CloverPit readiness
- whether CloverPit is running
- whether the expected CloverPit window is visible
- BACK / NEXT availability and destination
- all important action buttons and whether each is enabled
- disabled reason for each unavailable action
- last action
- last transition: source, action, destination, accepted/rejected
- installer state, progress, and current installer message
- last structured error

Example target:

```json
{
  "screen": "steamClient",
  "state": "steamReady",
  "actions": {
    "back": {"enabled": true, "target": "steamInstaller"},
    "next": {"enabled": true, "target": "cloverPit"}
  },
  "steam": {
    "exe_present": true,
    "lifecycle": "verifiedComplete",
    "running": true,
    "window_visible": true
  },
  "last_transition": {
    "from": "steamInstaller",
    "action": "next",
    "to": "steamClient",
    "accepted": true
  },
  "last_error": null
}
```

## Structured event/error stream

MacsTeam must emit machine-readable events, preferably NDJSON, for important state changes:

- app_started
- screen_changed
- button/action invoked
- navigation accepted/rejected
- runtime selected/loaded
- prefix selected/created/reused
- installer started/progress/message/completed/failed
- Steam detected/reconciled/launched/exited
- Steam window visible/hidden
- CloverPit checked/ready/not-ready
- CloverPit launched/exited
- CloverPit target window visible/hidden
- session ownership changes
- structured errors

Errors should look like:

```json
{
  "event": "transition_failed",
  "screen": "steamClient",
  "action": "next",
  "error": {
    "subsystem": "navigation",
    "code": "steam_lifecycle_not_ready",
    "expected": "verifiedComplete",
    "actual": "absent"
  }
}
```

The goal is for the AI to read the terminal and identify the blocker directly.

## Action flags / UI contract

BACK, NEXT, CHECK, INSTALL, LAUNCH, RETRY, STOP, and other meaningful buttons must have stable machine-readable action identifiers.

The UI renders the canonical action model. The terminal reads and invokes that same model.

Required shape conceptually:

```text
SwiftUI button ─┐
                ├─> canonical production intent/coordinator
CLI action   ───┘
```

No direct state injection and no CLI-only shadow state machine.

## Terminal control target

Target commands may be named differently, but the functionality should converge on something like:

```bash
macsteamctl status --json
macsteamctl events --follow
macsteamctl next
macsteamctl back
macsteamctl retry
macsteamctl runtime select imported-wine
macsteamctl prefix prepare
macsteamctl steam inspect
macsteamctl steam launch
macsteamctl cloverpit check
macsteamctl cloverpit launch
macsteamctl doctor --json
```

Installer operations and installer messages should also be available from the terminal rather than hidden inside SwiftUI.

## Doctor output

`doctor` should answer the question "why can the application not continue right now?"

It should derive a concise blocker from the current production state and recent structured events, for example:

```text
BLOCKED: Steam lifecycle mismatch
CURRENT SCREEN: Steam Client
EXPECTED: verifiedComplete
ACTUAL: absent
EVIDENCE: current-prefix Steam payload exists
LIKELY BLOCKER: reconciliation did not run after prefix reuse
LAST TRANSITION: Steam Installer -> Steam Client
```

## Few-step implementation roadmap

### Step 1 — State mirror + structured events

Expose the canonical coordinator/UI/action/runtime/Steam/CloverPit state as JSON and add the structured event/error stream. Include BACK/NEXT and installer messages.

**Result:** AI can inspect the application without screenshots or asking the user what the screen says.

### Step 2 — Terminal control over production intents

Add terminal commands that invoke the same production intents used by SwiftUI. Include navigation, retry, runtime/prefix preparation, Steam inspection/launch, CloverPit check/launch, and installer actions where applicable.

**Result:** AI can both observe and operate MacsTeam from the terminal.

### Step 3 — Doctor + one end-to-end run

Add blocker diagnosis from canonical state/events, then run one end-to-end terminal-observed flow. Fix only real blockers encountered. Keep human involvement to unavoidable authentication/visual confirmation.

**Result:** the user no longer has to stop at every screen. The AI can follow state -> action -> result -> error -> next action continuously.

## Definition of done

This PR is done when an AI can, from the terminal:

1. determine exactly what MacsTeam screen/state it is on;
2. know which actions are available and why unavailable actions are blocked;
3. read installer messages and progress;
4. know whether Windows Steam is installed, ready, running, and whether its expected window is visible;
5. know whether CloverPit is ready, running, and whether its expected window is visible;
6. invoke the same production BACK/NEXT/CHECK/INSTALL/LAUNCH/RETRY actions as the GUI;
7. read a structured error when any step fails;
8. diagnose the immediate blocker without asking the user to inspect the application;
9. continue through the setup/launch flow in one continuous AI-driven session except for genuinely human-only interactions.

## Explicitly out of scope while building this control plane

- repeated numbered acceptance attempts
- per-change proof rounds
- per-change Review Gate ceremony
- public playability promotion
- release packaging work
- redesigning Wine compatibility that is unrelated to observability/control

One final build/test/smoke is enough after the control plane works.

## Current source of truth

- Parent implementation branch: `feat/ultimate-cloverpit-u1`
- Starting parent SHA: `206fd94fa925d4d3bf4fa6586e5119157eaf6440`
- This PR branch: `feat/ai-terminal-control-plane`
- This document is the canonical roadmap for this PR. If chat context becomes noisy or truncated, reload this file first before deciding the next implementation step.

## Current progress

```yaml
current_progress:
  step1: DONE
  step2: DONE
  step3: DONE
  step3_fix1: DONE
  step3_fix2: DONE
  state_mirror: WORKING
  structured_events: WORKING
  terminal_status: WORKING
  terminal_events: WORKING
  terminal_commands: WORKING
  production_intent_routing: WORKING
  heartbeat: WORKING
  doctor: WORKING
  autonomous_cloverpit_run: WORKING
  staged_cloverpit_routing: WORKING
  flow_stall_on_staged_payload: FIXED
  control_plane: COMPLETE
  steam_process_observability: WORKING
  steam_window_visibility: WORKING
  steam_visible_error_capture: WORKING
  steam_log_error_capture: WORKING
  terminal_error_diagnosis: WORKING
  user_step_by_step_supervision_required: false
```
