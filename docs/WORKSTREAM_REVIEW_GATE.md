# Workstream Review Gate — R7

One NX = one workstream. One submitted commit per workstream. This gate enforces
sequential advancement on a single PR.

## Design principle

The worker submits exactly one commit per workstream. Before the next
workstream can start, a controller review must be anchored to the exact
commit that was submitted. This gate is the GitHub-native enforcer: CI fails
(RED) if a push introduces a commit whose parent lacks an accepted controller
review.

The gate does **not** auto-advance. It does not generate NX. It does not
merge. After review completes, a new user-supplied NX is required to start the
next workstream.

## Key terms

| Term | Meaning |
|---|---|
| **worker report** | Top-level PR Conversation issue comment containing the `<!-- macsteam-worker-report:v1 -->` marker and a JSON block. Emitted by the worker after finishing a workstream. |
| **controller review** | GitHub pull-request **review** object (not an issue comment) containing the `<!-- macsteam-controller-review:v1 -->` marker and a JSON block. Emitted by the controller to authorize advancement. |
| **phase** | One of `advance`, `submission`, `review`. Each phase validates a progressively stricter set of conditions. |

## Phases

### advance

Runs automatically on PR `opened`/`synchronize`/`reopened` events.

Verifies:
- PR is Open, Draft, Unmerged, Mergeable
- PR HEAD matches `--expected-head`
- HEAD commit has exactly one parent (no merge commits)
- Parent commit carries an accepted controller review (or bootstrap exception)
- Parent review was submitted before the child commit was created

Outputs `CURRENT_WORKSTREAM_ACTIVE`. The next commit is **not** admitted until
a controller review on the parent is confirmed.

### submission

Runs manually via `workflow_dispatch` after the worker posts their report.

Additionally verifies:
- A valid worker report exists as a top-level issue comment (not in a review)
- Report JSON matches the schema
- Report `head_sha`, `parent_sha`, `commit_count` are correct
- `stop == true`, `next_workstream_started == false`, no ready/merge/release
- Worker report was posted after the HEAD commit
- Declared core CI run exists for the exact HEAD, is `completed`/`success`
- All required CI jobs passed

Outputs `WAITING_FOR_CONTROLLER_REVIEW`.

### review

Runs manually via `workflow_dispatch` after the controller posts their review.

Additionally verifies:
- A valid controller review exists as a PR review (not an issue comment)
- Review `commit_id` matches the exact HEAD
- `decision == accepted`, `classification` starts with `GREEN_`
- `review_complete == true`
- Review was submitted after the worker report
- No newer CHANGES_REQUESTED/DISMISSED review overrides the accepted review

Outputs `REVIEW_COMPLETE_NX_REQUIRED`. The next workstream still requires a
new user NX.

## Bootstrap exception

The bootstrap tuple in `.github/workstage-review-gate-policy.json` records the
R3 workstream's final commit and its review. It is usable **only** for the R7
direct child of the bootstrap head. After R7, the bootstrap is never reused.

The bootstrap review (by ID) predates the v1 marker protocol, so it is verified
by commit ID match and APPROVED state rather than by marker.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Phase contract satisfied |
| 1 | Policy/protocol violation (guard label in output) |
| 2 | Infrastructure failure (API error, parse failure, missing file) |

## Local testing

```bash
# Verify clean fixtures pass
bash scripts/test-workstage-review-gate.sh
```

## Permissions

The gate workflow runs with read-only permissions:

```yaml
permissions:
  contents: read
  pull-requests: read
  issues: read
  actions: read
```

`pull_request_target` is never used. `persist-credentials: true` is never used.
