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
- The report is fetched by exact comment ID (`--worker-report-comment-id`)
- Exactly one current-HEAD worker report exists (no duplicates/replies/inline)
- Report JSON matches the schema (full validation, not partial)
- Report `head_sha`, `parent_sha`, `commit_count` are correct
- `stop == true`, `next_workstream_started == false`, no ready/merge/release
- `gate_submission_run_id == null` (contract `const: null`)
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
- The accepted review carries `worker_report_comment_id` and `submission_run_id`
  (both int ≥ 1), and the referenced submission run receipt validates (§8)

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

## Repair authorization — R7-FIX2

The repair authorization is a one-time exception for the `U1R18-R7-FIX2`
workstream. The parent commit `4b7cbe1...` was RED (canonical submission receipt
not bound). This repair authorization allows exactly one direct child commit that:

- Has parent == `4b7cbe1...`
- Is not a merge commit
- Has commit message exactly matching `ci: bind trusted submission receipt (U1R18-R7-FIX2)`
- Has `Workstream: U1R18-R7-FIX2` trailer
- Changes only files in the allowed path set (§3)
- Has production source delta 0 (no `Sources/**` or `Tests/**` changes)

The repair authorization is linked to the exact controller RED review with ID
`4843792148`, anchored to `4b7cbe1...`, whose body contains the exact
classification `RED_U1R18_R7_FIX1_CANONICAL_SUBMISSION_RECEIPT_NOT_BOUND`.

## Submission run receipt (§8)

The trusted submission run is the binding artifact that connects a worker report
to a controller review. The worker never creates reviews; in the submission phase
the gate always runs with `--worker-report-comment-id`, binding the report the
worker just posted.

- The worker report is queried by its comment ID (`issues/comments/{id}`).
- `gate_submission_run_id` must be `null` in the pre-submission worker report
  (contract `const: null`); it is derived only from `GITHUB_RUN_ID`.
- When a controller review is accepted, its body must carry
  `worker_report_comment_id` (int ≥ 1) and `submission_run_id` (int ≥ 1)
  (contract `controller-review.schema.json`, `additionalProperties: false`).

The submission run receipt is validated against the workflow-run contract:

- `event == workflow_dispatch`, `status == completed`, `conclusion == success`
- `run_attempt == 1`
- Run name encodes `phase=submission`, exact `PR`, exact `HEAD`, and `REPORT=<comment id>`
- Exactly one `Submission Gate` job, `completed`/`success`
- Chronology: commit < report_created_at < submission_run_started <
  submission_run_completed_at ≤ controller_review_submitted_at

## Future-child advance (§9)

When a later workstream's child advances and its **parent** controller review
carries `submission_run_id ≥ 1`, the gate revalidates that parent submission run
receipt before admitting the child. This prevents a chain from proceeding on an
unverified or replayed submission receipt.

## Worker/controller separation

The worker NEVER creates reviews and never authors controller reviews. Only the
controller credential (with `pull_requests: write`) may post a controller
review. The controller review must reference the worker report by comment ID and
the submission run by ID, so every controller action is provably bound to a
gate-run submission receipt.

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
