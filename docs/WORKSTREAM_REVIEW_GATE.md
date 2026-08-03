# Workstream Review Gate — R7 / U1R18-R7-FIX1

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

## Authority model — R7-FIX1 boundary

When a worker and controller operate under the same `author.login` in this
repository, the repository code alone cannot cryptographically distinguish them.

The repository gate enforces review-object sequencing. Controller identity
separation requires a credential that the Worker cannot use to create
pull-request reviews. Specifically:

- Worker credentials: `contents: write`, `issues: write`, `actions: write`,
  `pull_requests: read`.
- Controller credentials: `pull_requests: write` only.

The Worker never creates, edits, or dismisses controller reviews. The Worker
never executes the live `review` phase. The Worker may use offline fixture
mode to test the `review` phase locally.

## Key terms

| Term | Meaning |
|---|---|
| **worker report** | Top-level PR Conversation issue comment containing the `<!-- macsteam-worker-report:v1 -->` marker and a JSON block. Emitted by the worker after finishing a workstream. |
| **controller review** | GitHub pull-request **review** object (not an issue comment) containing the `<!-- macsteam-controller-review:v1 -->` marker and a JSON block. Emitted by the controller to authorize advancement. |
| **phase** | One of `advance`, `submission`, `review`. Each phase validates a progressively stricter set of conditions. |
| **repair authorization** | One-time exception recorded in policy that allows a direct child commit of a RED parent to repair the R7 workstream. Validates exact review ID, exact classification, exact commit message, Workstream trailer, changed paths, and production-source-delta 0. |

## Phases

### advance

Runs automatically on PR `opened`/`synchronize`/`reopened` events.

Verifies:
- Policy/live truth binding: repository, PR number, branch, and base all match policy
- PR is Open, Draft, Unmerged, Mergeable
- PR HEAD matches `--expected-head`
- HEAD commit has exactly one parent (no merge commits)
- Parent commit carries an accepted controller review (or valid repair/bootstrap exception)
- The review was submitted before the child commit was created

Parent review path selection:
1. **Bootstrap**: parent == `bootstrap.head_sha` AND child == `bootstrap.only_child_head`
2. **Repair**: parent == `repair_authorization.parent_sha`
3. **Normal**: any other parent

Outputs `CURRENT_WORKSTREAM_ACTIVE` with `parent_authority` field indicating
which path was used (`bootstrap`, `repair_authorization`, or `controller_review`).

### submission

Runs manually via `workflow_dispatch` after the worker posts their report.

Additionally verifies:
- A valid worker report exists as a top-level issue comment (not in a review)
- Report JSON matches the schema (full validation, not partial)
- Report `head_sha`, `parent_sha`, `commit_count` are correct
- `stop == true`, `next_workstream_started == false`, no ready/merge/release
- Worker report was posted after the HEAD commit
- Declared core CI run exists for the exact HEAD, is `completed`/`success`
- Workflow name is exactly `CI`
- All required CI jobs passed (each exactly one, all success, no duplicates)
- Historical worker reports for other HEADs do not conflict

Outputs `WAITING_FOR_CONTROLLER_REVIEW`.

### review

Runs manually via `workflow_dispatch` after the controller posts their review.

Additionally verifies:
- A valid controller review exists as a PR review (not an issue comment)
- Review `commit_id` matches the exact HEAD
- Marker exactly 1 in body
- JSON block exactly 1 in body
- `kind == controller_review`
- `head_sha == exact reviewed head`
- `decision == accepted`
- `classification` starts with `GREEN_`
- `review_complete == true`
- `nx_required_for_next_workstream == true`
- `ready_authorized == false`, `merge_authorized == false`, `release_authorized == false`
- Not in quarantined review IDs
- Submitted after the worker report
- No newer rejected/CHANGES_REQUESTED/DISMISSED review overrides the accepted review

Outputs `REVIEW_COMPLETE_NX_REQUIRED`.

## Bootstrap exception

The bootstrap tuple in `.github/workstage-review-gate-policy.json` records the
R3 workstream's final commit and its review. It is usable **only** for the R7
direct child of the bootstrap head (verified by `only_child_head`). After R7,
the bootstrap is never reused.

The bootstrap review (by ID) predates the v1 marker protocol, so it is verified
by exact commit ID match, exact state, and exact classification in the body
rather than by marker. `classification.startswith("GREEN_")` alone never grants
approval — the exact classification string must appear in the review body.

## Repair authorization — R7-FIX1

The repair authorization is a one-time exception for the `U1R18-R7-FIX1`
workstream. The parent commit `f3ae89d...` was RED (self-review + fail-open).
This repair authorization allows exactly one direct child commit that:

- Has parent == `f3ae89d...`
- Is not a merge commit
- Has commit message exactly matching `ci: close workstream review authority gate (U1R18-R7-FIX1)`
- Has `Workstream: U1R18-R7-FIX1` trailer
- Changes only files in the allowed path set (§3)
- Has production source delta 0 (no `Sources/**` or `Tests/**` changes)

The repair authorization is linked to the exact controller RED review with ID
`4841397951`, anchored to `f3ae89d...`, whose body contains the exact
classification `RED_U1R18_R7_SELF_REVIEW_AND_SEQUENTIAL_GATE_FAIL_OPEN`.

## Latest-decision authority

When multiple controller reviews exist for the same exact HEAD:

1. Extract all marker-present, schema-valid controller reviews for that HEAD
2. Sort by `submitted_at`
3. The latest valid controller decision is authoritative
4. If the latest decision is `rejected`, older `accepted` reviews are invalid
5. A newer `CHANGES_REQUESTED` or `DISMISSED` review also invalidates `accepted`

## Quarantine

The review with ID `4841357081` is a Worker-authored self-review that is
explicitly quarantined. Quarantined reviews are invalid in every context:
current-head review, parent review, bootstrap, repair authorization, and
fixtures.

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
The Worker's GitHub token must not have `pull_requests: write`. Only the
controller credential has `pull_requests: write`.

## R5

R5 external real-Mac proof requirement was removed by product-owner decision.
No external proof was performed or claimed.
