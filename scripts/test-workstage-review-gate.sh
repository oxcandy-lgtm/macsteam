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

# The FIX3 workflow YAML audit requires PyYAML. The gate itself still fails
# closed (exit 2) on unparseable YAML without it, but the semantic-audit
# harness section can only run when PyYAML is available.
HAS_YAML=$(python3 -c "import yaml; print('yes')" 2>/dev/null || echo "no")

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Unique positive run IDs so each hosted (submission) gate run is distinct.
HOSTED_RUN_SEQ=30000000000
next_hosted_run_id() {
  HOSTED_RUN_SEQ=$((HOSTED_RUN_SEQ + 1))
  echo "$HOSTED_RUN_SEQ"
}

# --- Provide the synthetic hosted context for submission-phase gate runs ---
# FIX3: only production live mode fails closed; the fixture harness must supply
# an explicit synthetic hosted context so submission fixtures exercise their
# real checks instead of dying on hosted_submission_context_missing.
HOSTED_ENV_VARS=(GITHUB_ACTIONS GITHUB_EVENT_NAME GITHUB_REPOSITORY
                 GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_WORKFLOW)
set_hosted_env() {
  export GITHUB_ACTIONS="true"
  export GITHUB_EVENT_NAME="workflow_dispatch"
  export GITHUB_REPOSITORY="oxcandy-lgtm/macsteam"
  export GITHUB_RUN_ID="$(next_hosted_run_id)"
  export GITHUB_RUN_ATTEMPT="1"
  export GITHUB_WORKFLOW="Workstream Review Gate"
}
clear_hosted_env() {
  for v in "${HOSTED_ENV_VARS[@]}"; do
    unset "$v" 2>/dev/null || true
  done
}

# --- Run the gate, capturing stdout and the exit code ---
GATE_OUT=""
GATE_RC=0
run_gate_env() {
  local gate="$1"
  local phase="$2"
  shift 2
  if [ "$phase" = "submission" ]; then
    set_hosted_env
  fi
  set +e
  GATE_OUT=$(python3 "$gate" "$@" 2>&1)
  GATE_RC=$?
  set -e
  if [ "$phase" = "submission" ]; then
    clear_hosted_env
  fi
}

guard_of() {
  python3 -c '
import sys, json
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if isinstance(d, dict) and "guard_label" in d:
        print(d.get("guard_label", ""))
        sys.exit(0)
sys.exit(0)
' 2>/dev/null || echo ""
}

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

  run_gate_env "$GATE" "$phase" \
    --phase "$phase" \
    --pr-number 2 \
    --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" \
    --fixtures "$fixture_dir" \
    --policy "$policy_arg" \
    $extra_args
  return "$GATE_RC"
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

  run_gate_env "$GATE" "$phase" \
    --phase "$phase" \
    --pr-number 2 \
    --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" \
    --fixtures "$fixture_dir" \
    --policy "$policy_arg" \
    $extra_args
  return "$GATE_RC"
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

  run_gate_env "$mut_gate" "$phase" \
    --phase "$phase" \
    --pr-number 2 \
    --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" \
    --fixtures "$fixture_dir" \
    --policy "$DEFAULT_POLICY" \
    $extra_args
  return "$GATE_RC"
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
  "advance_product_after_gate1|advance|"
  "gate1_report_matches_head_trailer|submission|--worker-report-comment-id 5161887211"
  "future_product_report_uses_fix1|submission|--worker-report-comment-id 5161887211"
  "latest_accept_after_reject|review|--worker-report-comment-id 5161887211"
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
  "repair_wrong_decision"
  "repair_wrong_review_state"
  "repair_malformed_json"
  "repair_marker_duplicated"
  "repair_json_head_mismatch"
  "repair_review_incomplete"
  "repair_nx_required_false"
  "repair_unsafe_authorization"
  "repair_review_after_child"
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
  "head_commit_message_missing"
  "head_workstream_trailer_missing"
  "head_workstream_trailer_duplicated"
  "head_workstream_trailer_invalid"
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
# TEST 2h: FIX3 review receipt — display_title / workflow identity / gate job
# ================================================
echo ""
echo "=== Fixture Mutations: FIX3 Receipt Display Title / Workflow Identity ==="

# name|expected_guard
FIX3_RECEIPT_MUTATIONS=(
  "receipt_display_title_wrong_phase|receipt_display_title_wrong_phase"
  "receipt_display_title_wrong_pr|receipt_display_title_wrong_pr"
  "receipt_display_title_wrong_head|receipt_display_title_wrong_head"
  "receipt_display_title_wrong_report|receipt_display_title_wrong_report"
  "receipt_submission_job_wrong_name|receipt_submission_job_wrong_name"
  "receipt_wrong_workflow_path|receipt_wrong_workflow_path"
)

for entry in "${FIX3_RECEIPT_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_guard <<< "$entry"
  base_dir="${FIXTURE_DIR}/green/review_exact_submission_receipt"
  fixture_dir="${TEMP_BASE}/fm_${mut_name}"
  rm -rf "$fixture_dir"
  mkdir -p "$fixture_dir"
  cp -r "${base_dir}/." "$fixture_dir/"
  expected_head=$(python3 -c "import json; print(json.load(open('${fixture_dir}/pr.json'))['head']['sha'])")
  python3 "${FIXTURE_DIR}/apply-mutation.py" "$mut_name" "$fixture_dir" 2>/dev/null || true
  run_gate_env "$GATE" "review" \
    --phase review --pr-number 2 --expected-head "$expected_head" \
    --repo "oxcandy-lgtm/macsteam" --fixtures "$fixture_dir" \
    --policy "$(get_policy_arg "$fixture_dir")" --worker-report-comment-id 5161887211
  if [ "$GATE_RC" -ne 0 ] && [ "$(guard_of <<< "$GATE_OUT")" = "$expected_guard" ]; then
    ok
    echo "  PASS: ${mut_name} (${expected_guard})"
  else
    bad "${mut_name} expected guard ${expected_guard}, got rc=${GATE_RC} guard=$(guard_of <<< "$GATE_OUT")"
  fi
done

# ================================================
# TEST 2i: FIX3 hosted submission context — fail closed without synthetic env
# ================================================
echo ""
echo "=== Fixture Mutations: FIX3 Hosted Submission Context (fail-closed) ==="

fixture_dir="${TEMP_BASE}/hf_hosted"
rm -rf "$fixture_dir"
mkdir -p "$fixture_dir"
cp -r "${FIXTURE_DIR}/green/submission_exact_comment_id/." "$fixture_dir/"
expected_head=$(python3 -c "import json; print(json.load(open('${fixture_dir}/pr.json'))['head']['sha'])")
run_gate_env "$GATE" "advance" \
  --phase submission --pr-number 2 --expected-head "$expected_head" \
  --repo "oxcandy-lgtm/macsteam" --fixtures "$fixture_dir" \
  --policy "$DEFAULT_POLICY" --worker-report-comment-id 5161887711
if [ "$GATE_RC" -eq 2 ] && [ "$(guard_of <<< "$GATE_OUT")" = "hosted_submission_context_missing" ]; then
  ok
  echo "  PASS: hosted_submission_context_missing (no synthetic env)"
else
  bad "hosted submission context should fail closed (rc=${GATE_RC}, guard=$(guard_of <<< "$GATE_OUT"))"
fi

# ================================================
# TEST 2j: Workflow semantic audit (--check-workflow)
# ================================================
echo ""
echo "=== Workflow Semantic Audit (FIX3 §12) ==="

if [ "$HAS_YAML" != "yes" ]; then
  echo "  SKIP: PyYAML unavailable; workflow YAML audit tests skipped (gate still fails closed)"
else
REAL_WORKFLOW="${SCRIPT_DIR}/../.github/workflows/workstage-review-gate.yml"
wf_tmp="${TEMP_BASE}/wf-workflow.yml"
cp "$REAL_WORKFLOW" "$wf_tmp"
run_gate_env "$GATE" "advance" --check-workflow "$wf_tmp"
WF_STATE=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('state',''))" <<< "$GATE_OUT" 2>/dev/null)
if [ "$GATE_RC" -eq 0 ] && [ "$WF_STATE" = "WORKFLOW_AUDIT_OK" ]; then
  ok
  echo "  PASS: workflow audit baseline (rc=0, WORKFLOW_AUDIT_OK)"
else
  bad "workflow audit baseline should succeed (rc=$GATE_RC state=$WF_STATE)"
fi

run_workflow_mutation() {
  local mut_name="$1"
  local expected_rc="$2"
  local fixture_dir="${TEMP_BASE}/wf_${mut_name}"
  mkdir -p "$fixture_dir"
  cp "$REAL_WORKFLOW" "$fixture_dir/workflow.yml"
  python3 "${FIXTURE_DIR}/apply-mutation.py" "$mut_name" "$fixture_dir" 2>/dev/null || true
  run_gate_env "$GATE" "advance" --check-workflow "$fixture_dir/workflow.yml"
  if [ "$GATE_RC" = "$expected_rc" ]; then
    ok
    echo "  PASS: workflow audit ${mut_name} (rc=$expected_rc)"
  else
    bad "workflow ${mut_name} expected rc=$expected_rc, got rc=$GATE_RC guard=$(guard_of <<< "$GATE_OUT")"
  fi
}

WF_BREACH_RC1=(
  "workflow_worker_report_input_missing"
  "workflow_worker_report_input_optional"
  "workflow_submission_cli_arg_missing"
  "workflow_submission_cli_arg_hardcoded"
  "workflow_review_cli_arg_missing"
  "workflow_run_name_missing"
  "workflow_run_name_missing_phase"
  "workflow_run_name_missing_pr"
  "workflow_run_name_missing_head"
  "workflow_run_name_missing_report"
  "workflow_submission_job_wrong_name"
  "workflow_submission_job_duplicate"
  "workflow_generic_manual_job_restored"
  "workflow_submission_condition_too_broad"
  "workflow_checkout_expected_head_missing"
  "workflow_inputs_block_missing"
)
for m in "${WF_BREACH_RC1[@]}"; do
  run_workflow_mutation "$m" 1
done
run_workflow_mutation "workflow_yaml_unparseable" 2
run_workflow_mutation "workflow_jobs_block_missing" 2

TOTAL_FIX3="${#FIX3_RECEIPT_MUTATIONS[@]}"
echo ""
echo "  (FIX3 workflow audit: ${#WF_BREACH_RC1[@]} rc=1 checks + 2 rc=2 checks)"
fi
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
  "receipt_dynamic_identity_reads_name_not_display_title|review_exact_submission_receipt|review|--worker-report-comment-id 5161887211"
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
# The two product WIP files below are intentionally carried (uncommitted) from
# upstream work and must be preserved byte-for-byte; the gate must never add or
# modify any other production source. Only unexpected changes are flagged.
ALLOWED_WIP=(
  "Sources/MacSteam/Services/RecipeLoader.swift"
  "Tests/MacSteamTests/CloverPitRecipeAuthorityTests.swift"
)
if [ -d "${WORKTREE_DIR}/.git" ]; then
  CHANGED=$(git -C "$WORKTREE_DIR" diff --name-only -- Sources Tests 2>/dev/null || true)
  FLAGGED=""
  if [ -n "$CHANGED" ]; then
    while IFS= read -r f; do
      keep=0
      for allowed in "${ALLOWED_WIP[@]}"; do
        [ "$f" = "$allowed" ] && keep=1 && break
      done
      [ "$keep" = "0" ] && FLAGGED="${FLAGGED} ${f}"
    done <<< "$CHANGED"
  fi
  if [ -n "$FLAGGED" ]; then
    bad "Production source files modified (beyond allowed WIP): $FLAGGED"
  else
    ok
    echo "  PASS: No unexpected production source changes (Sources/ or Tests/)"
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
