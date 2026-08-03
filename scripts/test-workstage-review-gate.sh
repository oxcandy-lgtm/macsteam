#!/usr/bin/env bash
set -euo pipefail

# Test harness for workstage-review-gate — U1R18-R7-FIX1
# Tests GREEN fixtures pass, mutations cause failures, source mutations are caught

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
    --policy "$policy_arg" > /dev/null 2>&1
}

# --- Run a fixture with a fixture mutation, expect failure ---
run_fixture_mutation() {
  local mut_name="$1"
  local phase="$2"
  local base_fixture="$3"
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
    --policy "$policy_arg" > /dev/null 2>&1
}

# --- Run a fixture with a source mutation, expect failure ---
run_source_mutation() {
  local mut_name="$1"
  local fixture_name="$2"
  local phase="$3"
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
    --policy "$DEFAULT_POLICY" > /dev/null 2>&1
}

# ================================================
# TEST 1: All GREEN fixtures pass (baseline)
# ================================================
echo "=== GREEN Fixtures (baseline) ==="

GREEN_FIXTURES=(
  "advance_bootstrap:advance"
  "advance_repair:advance"
  "advance_normal_commented:advance"
  "advance_normal_approved:advance"
  "submission_historical_reports:submission"
  "submission_historical_reviews:submission"
  "review_commented_accepted:review"
  "review_approved_accepted:review"
  "multi_page_comments:submission"
  "multi_page_reviews:advance"
  "multi_page_runs_jobs:submission"
  "latest_accept_after_reject:review"
)

for entry in "${GREEN_FIXTURES[@]}"; do
  fixture="${entry%%:*}"
  phase="${entry##*:}"
  fixture_dir="${FIXTURE_DIR}/green/${fixture}"
  
  if run_green_pass "$fixture_dir" "$phase"; then
    ok
    echo "  PASS: green/${fixture} (${phase})"
  else
    bad "green/${fixture} (${phase}) should pass"
  fi
done

# ================================================
# TEST 2: Fixture mutations cause failures
# ================================================
echo ""
echo "=== Fixture Mutations (should fail) ==="

# Format: mut_name|phase|base_fixture
FIXTURE_MUTATIONS=(
  "quarantined_self_review_rejected|advance|advance_normal_approved"
  "parent_review_missing|advance|advance_normal_approved"
  "parent_review_issue_comment_only|advance|advance_normal_approved"
  "parent_review_wrong_head|advance|advance_normal_approved"
  "parent_review_after_child|advance|advance_normal_approved"
  "parent_review_commented_without_marker|advance|advance_normal_approved"
  "parent_review_approved_with_bad_json|advance|advance_normal_approved"
  "latest_rejected_overrides_old_green|advance|advance_normal_approved"
  "selected_changes_requested|advance|advance_normal_approved"
  "selected_dismissed|advance|advance_normal_approved"
  "controller_json_head_mismatch|advance|advance_normal_approved"
  "controller_nx_required_false|advance|advance_normal_approved"
  "controller_ready_true|advance|advance_normal_approved"
  "controller_merge_true|advance|advance_normal_approved"
  "controller_release_true|advance|advance_normal_approved"
  "controller_review_complete_false|advance|advance_normal_approved"
  "controller_classification_not_green|advance|advance_normal_approved"
  "controller_marker_duplicated_in_body|advance|advance_normal_approved"
  "controller_json_blocks_duplicated|advance|advance_normal_approved"
  "bootstrap_policy_green_without_body_evidence|advance|advance_bootstrap"
  "bootstrap_wrong_review_id|advance|advance_bootstrap"
  "bootstrap_wrong_commit|advance|advance_bootstrap"
  "bootstrap_wrong_classification|advance|advance_bootstrap"
  "bootstrap_wrong_child|advance|advance_bootstrap"
  "bootstrap_reused_after_r7|advance|advance_bootstrap"
  "repair_wrong_review_id|advance|advance_repair"
  "repair_wrong_parent|advance|advance_repair"
  "repair_wrong_classification|advance|advance_repair"
  "repair_wrong_commit_message|advance|advance_repair"
  "repair_wrong_workstream_trailer|advance|advance_repair"
  "repair_forbidden_path|advance|advance_repair"
  "repair_production_source_changed|advance|advance_repair"
  "repair_merge_commit|advance|advance_repair"
  "repair_reused_after_fix1|advance|advance_repair"
  "repair_quarantined_review_used|advance|advance_repair"
  "report_missing|submission|submission_historical_reports"
  "report_malformed_current_head|submission|submission_historical_reports"
  "report_marker_duplicated|submission|submission_historical_reports"
  "report_json_block_duplicated|submission|submission_historical_reports"
  "report_inline|submission|submission_historical_reports"
  "report_reply|submission|submission_historical_reports"
  "report_head_mismatch|submission|submission_historical_reports"
  "report_parent_mismatch|submission|submission_historical_reports"
  "report_commit_count_invalid|submission|submission_historical_reports"
  "report_workstream_mismatch|submission|submission_historical_reports"
  "report_stop_false|submission|submission_historical_reports"
  "report_next_workstream_true|submission|submission_historical_reports"
  "report_ready_true|submission|submission_historical_reports"
  "report_merge_true|submission|submission_historical_reports"
  "report_release_true|submission|submission_historical_reports"
  "report_before_commit|submission|submission_historical_reports"
  "report_bool_used_as_integer|submission|submission_historical_reports"
  "report_duplicate_ci_jobs|submission|submission_historical_reports"
  "report_invalid_array_item|submission|submission_historical_reports"
  "report_extra_property|submission|submission_historical_reports"
  "duplicate_current_head_reports|submission|submission_historical_reports"
  "historical_reports_do_not_conflict|submission|submission_historical_reports"
  "ci_run_missing|submission|submission_historical_reports"
  "ci_run_wrong_head|submission|submission_historical_reports"
  "ci_run_wrong_workflow|submission|submission_historical_reports"
  "ci_run_incomplete|submission|submission_historical_reports"
  "ci_run_failed|submission|submission_historical_reports"
  "ci_job_missing|submission|submission_historical_reports"
  "ci_job_failed|submission|submission_historical_reports"
  "ci_job_duplicate|submission|submission_historical_reports"
  "policy_missing|advance|advance_normal_approved"
  "policy_malformed|advance|advance_normal_approved"
  "fixture_missing|advance|advance_normal_approved"
  "fixture_json_malformed|advance|advance_normal_approved"
  "pagination_parse_failure|submission|submission_historical_reports"
  "pagination_page_type_invalid|submission|submission_historical_reports"
  "pagination_duplicate_id|submission|submission_historical_reports"
  "timestamp_malformed|advance|advance_normal_approved"
  "commit_parent_missing|advance|advance_normal_approved"
  "mergeable_unknown_after_retry|advance|advance_normal_approved"
  "merge_commit_rejected|advance|advance_normal_approved"
  "repository_mismatch|advance|advance_normal_approved"
  "pr_number_mismatch|advance|advance_normal_approved"
  "head_branch_mismatch|advance|advance_normal_approved"
  "base_branch_mismatch|advance|advance_normal_approved"
  "pr_closed|advance|advance_normal_approved"
  "pr_not_draft|advance|advance_normal_approved"
  "pr_merged|advance|advance_normal_approved"
  "pr_not_mergeable|advance|advance_normal_approved"
  "expected_head_invalid|advance|advance_normal_approved"
  "api_404_pr|advance|advance_normal_approved"
  "api_404_commit|advance|advance_normal_approved"
  "api_404_comments|submission|submission_historical_reports"
  "api_404_reviews|advance|advance_normal_approved"
  "api_404_runs|submission|submission_historical_reports"
  "api_404_jobs|submission|submission_historical_reports"
)

for entry in "${FIXTURE_MUTATIONS[@]}"; do
  mut_name="${entry%%|*}"
  rest="${entry#*|}"
  phase="${rest%%|*}"
  fixture="${rest##*|}"
  base_fixture_dir="${FIXTURE_DIR}/green/${fixture}"
  
  if ! run_fixture_mutation "$mut_name" "$phase" "$base_fixture_dir"; then
    ok
    echo "  PASS: ${mut_name} (${fixture}:${phase})"
  else
    bad "${mut_name} (${fixture}:${phase}) should fail"
  fi
done

# ================================================
# TEST 3: Source mutations cause GREEN fixture failures
# ================================================
echo ""
echo "=== Source Mutations (should catch failures) ==="

# Format: mut_name|fixture_name|phase
SOURCE_MUTATIONS=(
  "m1_first_review_not_latest|latest_accept_after_reject|review"
  "m2_invert_before_report|review_commented_accepted|review"
  "m3_green_to_red_classification|review_approved_accepted|review"
  "m4_wrong_workstream|submission_historical_reports|submission"
  "m5_invert_before_commit|submission_historical_reports|submission"
  "m6_bootstrap_state_commented|advance_bootstrap|advance"
  "m7_approved_only_no_commented|advance_normal_commented|advance"
  "m8_invert_head_sha_check|advance_normal_approved|advance"
  "m9_invert_commit_count|submission_historical_reports|submission"
  "m10_invert_decision_check|advance_normal_approved|advance"
  "m11_invert_required_jobs|submission_historical_reports|submission"
  "m12_invert_draft_check|advance_normal_approved|advance"
  "m13_wrong_mergeable|advance_normal_approved|advance"
  "m14_remove_bootstrap_routing|advance_bootstrap|advance"
  "m15_invert_stop_check|submission_historical_reports|submission"
)

for entry in "${SOURCE_MUTATIONS[@]}"; do
  mut_name="${entry%%|*}"
  rest="${entry#*|}"
  fixture_name="${rest%%|*}"
  phase="${rest##*|}"
  
  if ! run_source_mutation "$mut_name" "$fixture_name" "$phase"; then
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
