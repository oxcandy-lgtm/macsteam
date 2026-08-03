#!/usr/bin/env bash
set -euo pipefail

# Test harness for workstage-review-gate — U1R18-R7-FIX2
# Tests: 20 GREEN fixtures pass, fixture mutations cause failures,
#        source mutations are caught, worktree is clean.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/workstage-review-gate-fixtures"
GATE="${SCRIPT_DIR}/workstage-review-gate.py"
DEFAULT_POLICY="${SCRIPT_DIR}/../.github/workstage-review-gate-policy.json"
TEMP_BASE="/tmp/wrg-test-$$"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

mkdir -p "$TEMP_BASE"

# --- Determine the policy file to use for a fixture directory ---
get_policy_arg() {
  local fixture_dir="$1"
  if [ -f "${fixture_dir}/policy.json" ]; then
    echo "${fixture_dir}/policy.json"
  else
    echo "$DEFAULT_POLICY"
  fi
}

# --- Run a GREEN fixture through the gate, expect success ---
run_green_pass() {
  local fixture_dir="$1"
  local phase="$2"
  local extra_args="$3"
  local expected_head
  expected_head=$(python3 -c "import json; print(json.load(open('${fixture_dir}/pr.json'))['head']['sha'])")
  local policy_arg
  policy_arg=$(get_policy_arg "$fixture_dir")

  python3 "$GATE" \
    --phase "$phase" \
    --pr-number 2 \
    --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" \
    --fixtures "$fixture_dir" \
    --policy "$policy_arg" \
    $extra_args > /dev/null 2>&1
}

# --- Run a fixture with a fixture mutation, expect failure ---
run_fixture_mutation() {
  local mut_name="$1"
  local phase="$2"
  local base_fixture="$3"
  local extra_args="$4"
  local fixture_dir="${TEMP_BASE}/fm_${mut_name}"

  rm -rf "$fixture_dir"
  mkdir -p "$fixture_dir"
  cp -r "${base_fixture}/." "$fixture_dir/"

  # Compute expected_head BEFORE mutation (some mutations remove pr.json)
  local expected_head
  if [ -f "${fixture_dir}/pr.json" ]; then
    expected_head=$(python3 -c "import json; print(json.load(open('${fixture_dir}/pr.json'))['head']['sha'])")
  else
    expected_head=$(python3 -c "import json; print(json.load(open('${base_fixture}/pr.json'))['head']['sha'])")
  fi

  # For policy-related mutations, ensure a policy.json exists first
  if [ "$mut_name" = "policy_missing" ]; then
    cp "$DEFAULT_POLICY" "${fixture_dir}/policy.json"
  fi

  python3 "${FIXTURE_DIR}/apply-mutation.py" "$mut_name" "$fixture_dir" 2>/dev/null || true

  # For policy_missing, always use the fixture path so the missing file is detected
  local policy_arg
  if [ "$mut_name" = "policy_missing" ]; then
    policy_arg="${fixture_dir}/policy.json"
  else
    policy_arg=$(get_policy_arg "$fixture_dir")
  fi

  python3 "$GATE" \
    --phase "$phase" \
    --pr-number 2 \
    --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" \
    --fixtures "$fixture_dir" \
    --policy "$policy_arg" \
    $extra_args > /dev/null 2>&1
}

# --- Run a fixture with a source mutation, expect failure ---
run_source_mutation() {
  local mut_name="$1"
  local fixture_name="$2"
  local phase="$3"
  local extra_args="$4"
  local fixture_dir="${TEMP_BASE}/sm_${mut_name}_${fixture_name}"

  rm -rf "$fixture_dir"
  mkdir -p "$fixture_dir"
  cp -r "${FIXTURE_DIR}/green/${fixture_name}/." "$fixture_dir/"

  local mut_gate="${TEMP_BASE}/gate_${mut_name}.py"
  cp "$GATE" "$mut_gate"
  python3 "${FIXTURE_DIR}/apply-source-mutation.py" "$mut_name" "$mut_gate" 2>/dev/null

  local expected_head
  expected_head=$(python3 -c "import json; print(json.load(open('${fixture_dir}/pr.json'))['head']['sha'])")

  python3 "$mut_gate" \
    --phase "$phase" \
    --pr-number 2 \
    --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" \
    --fixtures "$fixture_dir" \
    --policy "$DEFAULT_POLICY" \
    $extra_args > /dev/null 2>&1
}

# ================================================
# TEST 1: All GREEN fixtures pass (baseline)
# ================================================
echo "=== GREEN Fixtures (baseline) ==="

GREEN_FIXTURES=(
  "advance_bootstrap|advance|"
  "advance_repair|advance|"
  "advance_normal_commented|advance|"
  "advance_normal_approved|advance|"
  "latest_accept_after_reject|review|"
  "multi_page_comments|submission|--worker-report-comment-id 5161887211"
  "multi_page_reviews|advance|"
  "multi_page_runs_jobs|submission|--worker-report-comment-id 5161887211"
  "review_approved_accepted|review|--worker-report-comment-id 5161887211"
  "review_commented_accepted|review|--worker-report-comment-id 5161887211"
  "review_commented_accepted_with_receipt|review|--worker-report-comment-id 5161887211"
  "review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "submission_exact_comment_id|submission|--worker-report-comment-id 5161887211"
  "submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "submission_historical_reviews|submission|--worker-report-comment-id 5161887211"
  "submission_pre_report_null|submission|--worker-report-comment-id 5161887211"
  "submission_trusted_github_run_id|submission|--worker-report-comment-id 5161887211"
  "future_child_advance_revalidates_parent_receipt|advance|"
  "historical_reports_plus_one_current|submission|--worker-report-comment-id 5161887211"
  "historical_submission_runs_do_not_collide|review|--worker-report-comment-id 5161887211"
)

for entry in "${GREEN_FIXTURES[@]}"; do
  fixture="${entry%%|*}"
  rest="${entry#*|}"
  phase="${rest%%|*}"
  extra="${rest#*|}"
  fixture_dir="${FIXTURE_DIR}/green/${fixture}"

  if run_green_pass "$fixture_dir" "$phase" "$extra"; then
    ok
    echo "  PASS: green/${fixture} (${phase})"
  else
    bad "green/${fixture} (${phase}) should pass"
  fi
done

# ================================================
# TEST 2: Fixture mutations — advance phase (parent/controller) — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Advance Phase (parent/controller) ==="

ADVANCE_MUTATIONS=(
  "quarantined_self_review_rejected"
  "parent_review_missing"
  "parent_review_issue_comment_only"
  "parent_review_wrong_head"
  "parent_review_after_child"
  "parent_review_commented_without_marker"
  "parent_review_approved_with_bad_json"
  "latest_rejected_overrides_old_green"
  "selected_changes_requested"
  "selected_dismissed"
  "controller_json_head_mismatch"
  "controller_nx_required_false"
  "controller_ready_true"
  "controller_merge_true"
  "controller_release_true"
  "controller_review_complete_false"
  "controller_classification_not_green"
  "controller_marker_duplicated_in_body"
  "controller_json_blocks_duplicated"
  "bootstrap_policy_green_without_body_evidence"
  "bootstrap_wrong_review_id"
  "bootstrap_wrong_commit"
  "bootstrap_wrong_classification"
  "bootstrap_wrong_child"
  "bootstrap_reused_after_r7"
  "repair_wrong_review_id"
  "repair_wrong_parent"
  "repair_wrong_classification"
  "repair_wrong_commit_message"
  "repair_wrong_workstream_trailer"
  "repair_forbidden_path"
  "repair_production_source_changed"
  "repair_merge_commit"
  "repair_reused_after_fix1"
  "repair_quarantined_review_used"
)

for mut_name in "${ADVANCE_MUTATIONS[@]}"; do
  if [ "$mut_name" = "quarantined_self_review_rejected" ]; then
    base_fixture="advance_normal_approved"
  elif [[ "$mut_name" == bootstrap_* ]]; then
    base_fixture="advance_bootstrap"
  elif [[ "$mut_name" == repair_* ]]; then
    base_fixture="advance_repair"
  else
    base_fixture="advance_normal_approved"
  fi

  base_dir="${FIXTURE_DIR}/green/${base_fixture}"
  if ! run_fixture_mutation "$mut_name" "advance" "$base_dir" ""; then
    ok
    echo "  PASS: ${mut_name} (advance)"
  else
    bad "${mut_name} (advance) should fail"
  fi
done

# ================================================
# TEST 2b: Fixture mutations — submission phase (worker report) — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Phase (worker report) ==="

SUBMISSION_REPORT_MUTATIONS=(
  "report_missing"
  "report_malformed_current_head"
  "report_marker_duplicated"
  "report_json_block_duplicated"
  "report_inline"
  "report_reply"
  "report_head_mismatch"
  "report_parent_mismatch"
  "report_commit_count_invalid"
  "report_workstream_mismatch"
  "report_stop_false"
  "report_next_workstream_true"
  "report_ready_true"
  "report_merge_true"
  "report_release_true"
  "report_before_commit"
  "report_bool_used_as_integer"
  "report_duplicate_ci_jobs"
  "report_invalid_array_item"
  "report_extra_property"
  "duplicate_current_head_reports"
  "historical_reports_do_not_conflict"
  "report_submission_run_numeric"
  "report_submission_run_string"
  "report_submission_run_missing"
  "report_submission_run_id_non_null"
  "report_gate_submission_run_id_numeric"
  "report_gate_submission_run_id_string"
  "report_gate_submission_run_id_missing"
  "ci_run_missing"
  "ci_run_wrong_head"
  "ci_run_wrong_workflow"
  "ci_run_incomplete"
  "ci_run_failed"
  "ci_job_missing"
  "ci_job_failed"
  "ci_job_duplicate"
  "pagination_parse_failure"
  "pagination_page_type_invalid"
  "pagination_duplicate_id"
  "api_404_comments"
  "api_404_runs"
  "api_404_jobs"
  "fixture_missing_comments"
  "fixture_missing_runs"
  "fixture_missing_jobs"
)

for mut_name in "${SUBMISSION_REPORT_MUTATIONS[@]}"; do
  if ! run_fixture_mutation "$mut_name" "submission" "${FIXTURE_DIR}/green/submission_historical_reports" "--worker-report-comment-id 5161887211"; then
    ok
    echo "  PASS: ${mut_name} (submission)"
  else
    bad "${mut_name} (submission) should fail"
  fi
done

# ================================================
# TEST 2c: Fixture mutations — submission phase (run receipt) — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Run Receipt ==="

SUBMISSION_RECEIPT_MUTATIONS=(
  "submission_run_wrong_head"
  "submission_run_wrong_branch"
  "submission_run_wrong_event"
  "submission_run_wrong_phase_in_name"
  "submission_run_wrong_pr_in_name"
  "submission_run_wrong_report_id_in_name"
  "submission_run_wrong_head_in_name"
  "submission_run_attempt_gt_one"
  "submission_run_incomplete"
  "submission_run_failed"
  "submission_run_wrong_id"
  "submission_run_id_mismatch"
  "report_created_after_submission_run"
  "submission_completed_after_review"
)

for mut_name in "${SUBMISSION_RECEIPT_MUTATIONS[@]}"; do
  if ! run_fixture_mutation "$mut_name" "review" "${FIXTURE_DIR}/green/review_exact_submission_receipt" "--worker-report-comment-id 5161887211"; then
    ok
    echo "  PASS: ${mut_name} (review/submission-receipt)"
  else
    bad "${mut_name} (review/submission-receipt) should fail"
  fi
done

# ================================================
# TEST 2d: Fixture mutations — submission gate job — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Gate Job ==="

SUBMISSION_JOB_MUTATIONS=(
  "submission_gate_job_missing"
  "submission_gate_job_failed"
  "submission_gate_job_skipped"
  "submission_gate_job_cancelled"
  "submission_gate_job_duplicate"
)

for mut_name in "${SUBMISSION_JOB_MUTATIONS[@]}"; do
  if ! run_fixture_mutation "$mut_name" "review" "${FIXTURE_DIR}/green/review_exact_submission_receipt" "--worker-report-comment-id 5161887211"; then
    ok
    echo "  PASS: ${mut_name} (review/submission-job)"
  else
    bad "${mut_name} (review/submission-job) should fail"
  fi
done

# ================================================
# TEST 2e: Fixture mutations — submission run infra — should fail (exit 2)
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Run Infrastructure ==="

SUBMISSION_INFRA_MUTATIONS=(
  "api_404_submission_runs"
  "api_404_submission_jobs"
  "submission_runs_json_malformed"
  "submission_jobs_json_malformed"
  "submission_runs_page_type_invalid"
  "submission_runs_duplicate_id"
  "submission_job_id_non_integer"
  "fixture_missing_submission_runs"
  "fixture_missing_submission_jobs"
  "fixture_missing_submission_comment"
)

for mut_name in "${SUBMISSION_INFRA_MUTATIONS[@]}"; do
  if ! run_fixture_mutation "$mut_name" "submission" "${FIXTURE_DIR}/green/submission_exact_comment_id" "--worker-report-comment-id 5161887211"; then
    ok
    echo "  PASS: ${mut_name} (submission)"
  else
    bad "${mut_name} (submission) should fail"
  fi
done

# ================================================
# TEST 2f: Fixture mutations — controller review receipt — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Controller Review Receipt ==="

CONTROLLER_RECEIPT_MUTATIONS=(
  "controller_worker_report_comment_id_missing"
  "controller_submission_run_id_missing"
  "controller_worker_report_comment_id_zero"
  "controller_submission_run_id_zero"
  "controller_worker_report_comment_id_string"
  "controller_submission_run_id_string"
  "controller_receipt_wrong_comment_id"
  "controller_receipt_wrong_submission_run_id"
)

for mut_name in "${CONTROLLER_RECEIPT_MUTATIONS[@]}"; do
  if ! run_fixture_mutation "$mut_name" "review" "${FIXTURE_DIR}/green/review_commented_accepted_with_receipt" "--worker-report-comment-id 5161887211"; then
    ok
    echo "  PASS: ${mut_name} (review)"
  else
    bad "${mut_name} (review) should fail"
  fi
done

# ================================================
# TEST 2g: Fixture mutations — remaining infra/PR — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: PR / Policy / Infra ==="

PR_POLICY_MUTATIONS=(
  "repository_mismatch"
  "pr_number_mismatch"
  "head_branch_mismatch"
  "base_branch_mismatch"
  "pr_closed"
  "pr_not_draft"
  "pr_merged"
  "pr_not_mergeable"
  "expected_head_invalid"
  "policy_missing"
  "policy_malformed"
  "timestamp_malformed"
  "commit_parent_missing"
  "mergeable_unknown_after_retry"
  "merge_commit_rejected"
  "api_404_pr"
  "api_404_commit"
  "api_404_reviews"
  "fixture_missing_reviews"
  "fixture_missing_pr"
  "fixture_missing_commit"
  "fixture_json_malformed"
)

for mut_name in "${PR_POLICY_MUTATIONS[@]}"; do
  base_fixture="advance_normal_approved"
  if [[ "$mut_name" == repository_mismatch ]]; then
    base_fixture="advance_normal_approved"
  elif [[ "$mut_name" == expected_head_invalid ]]; then
    base_fixture="advance_normal_approved"
  fi
  base_dir="${FIXTURE_DIR}/green/${base_fixture}"
  if ! run_fixture_mutation "$mut_name" "advance" "$base_dir" ""; then
    ok
    echo "  PASS: ${mut_name} (advance)"
  else
    bad "${mut_name} (advance) should fail"
  fi
done

# ================================================
# TEST 3: Source mutations cause GREEN fixture failures
# ================================================
echo ""
echo "=== Source Mutations (should catch failures) ==="

# Format: mut_name|fixture_name|phase|extra_args
SOURCE_MUTATIONS=(
  "m1_first_review_not_latest|latest_accept_after_reject|review|"
  "m2_invert_before_report|review_commented_accepted|review|"
  "m3_green_to_red_classification|review_approved_accepted|review|"
  "m4_wrong_workstream|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m5_invert_before_commit|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m6_bootstrap_state_commented|advance_bootstrap|advance|"
  "m7_approved_only_no_commented|advance_normal_commented|advance|"
  "m8_invert_head_sha_check|advance_normal_approved|advance|"
  "m9_invert_commit_count|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m10_invert_decision_check|advance_normal_approved|advance|"
  "m11_invert_required_jobs|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m12_invert_draft_check|advance_normal_approved|advance|"
  "m13_wrong_mergeable|advance_normal_approved|advance|"
  "m14_remove_bootstrap_routing|advance_bootstrap|advance|"
  "m15_invert_stop_check|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m16_allow_non_null_submission_run_id|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m17_invert_comment_id_required|submission_historical_reports|submission|--worker-report-comment-id 5161887211"
  "m18_invert_submission_status_check|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m19_invert_submission_conclusion_check|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m20_invert_gate_job_status|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m21_invert_gate_job_conclusion|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m22_skip_chronology_check|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m23_invert_completed_after_review|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m24_skip_run_attempt_check|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
  "m25_bypass_submission_receipt|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
)

for entry in "${SOURCE_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name fixture_name phase extra <<< "$entry"
  if ! run_source_mutation "$mut_name" "$fixture_name" "$phase" "$extra"; then
    ok
    echo "  PASS: ${mut_name} caught by ${fixture_name}:${phase}"
  else
    bad "${mut_name} not caught by ${fixture_name}:${phase}"
  fi
done

# ================================================
# TEST 4: Worktree clean (no production source changes)
# ================================================
echo ""
echo "=== Worktree Check ==="
WORKTREE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -d "${WORKTREE_DIR}/.git" ]; then
  CHANGED=$(git -C "$WORKTREE_DIR" diff --name-only -- Sources Tests 2>/dev/null || true)
  if [ -n "$CHANGED" ]; then
    bad "Production source files modified: $CHANGED"
  else
    ok
    echo "  PASS: No production source changes (Sources/ or Tests/)"
  fi
else
  bad "Not a git repository at ${WORKTREE_DIR}"
fi

# ================================================
# Summary
# ================================================
echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

rm -rf "$TEMP_BASE"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
