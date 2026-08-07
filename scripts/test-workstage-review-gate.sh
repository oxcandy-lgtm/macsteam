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

# --- FIX1 §6: exact mutation verdict assertions ---
# Every mutation must declare its exact expected exit code AND exact guard
# label. No wildcard/default mapping is allowed: the map below is the single
# source of truth for both values and the runner asserts both. A malformed or
# missing expectation is a harness self-FAIL, never an implicit pass.
assert_rejected_exact() {
  # $1 mut_name | $2 expected_rc | $3 expected_guard | $4 label
  local mut_name="$1"
  local expected_rc="$2"
  local expected_guard="$3"
  local label="$4"
  local actual_guard
  actual_guard="$(guard_of <<< "$GATE_OUT")"

  if [ -z "$expected_rc" ]; then
    bad "HARNESS SELF-FAIL: ${mut_name} (${label}) has no expected_rc mapping"
    return 1
  fi
  if [ -z "$expected_guard" ]; then
    bad "HARNESS SELF-FAIL: ${mut_name} (${label}) has no expected_guard mapping"
    return 1
  fi
  # The sentinel _EMPTY_ encodes an explicitly expected empty guard label
  # (policy_missing / policy_malformed surface as rc=1 with no emitted guard).
  if [ "$expected_guard" = "_EMPTY_" ]; then
    expected_guard=""
  fi

  if [ "$GATE_RC" = "$expected_rc" ] && [ "$actual_guard" = "$expected_guard" ]; then
    ok
    echo "  PASS: ${mut_name} (${label}) rc=${GATE_RC} guard=${actual_guard}"
  else
    bad "${mut_name} (${label}) expected rc=${expected_rc} guard=${expected_guard}, got rc=${GATE_RC} guard=${actual_guard}"
  fi
}

# ================================================
# TEST 1: All GREEN fixtures pass (baseline)
# ================================================
echo "=== GREEN Fixtures (baseline) ==="

GREEN_FIXTURES=(
  "advance_bootstrap|advance|"
  "advance_repair|advance|"
  "r9_truth_scope_admitted|advance|"
  "advance_normal_commented|advance|"
  "advance_normal_approved|advance|"
  "advance_product_after_gate1|advance|"
  "advance_red_parent_source_fix_bridge|advance|"
  "advance_gate_fix_authorization|advance|"
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
  "historical_malformed_report_before_head|submission|--worker-report-comment-id 5161887211"
  "historical_valid_report_after_head_for_other_sha|submission|--worker-report-comment-id 5161887211"
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
  "quarantined_self_review_rejected|1|quarantined_self_review_rejected|advance_normal_approved"
  "parent_review_missing|1|parent_review_missing|advance_normal_approved"
  "parent_review_issue_comment_only|1|parent_review_missing|advance_normal_approved"
  "parent_review_wrong_head|1|parent_review_wrong_head|advance_normal_approved"
  "parent_review_after_child|1|parent_review_after_child|advance_normal_approved"
  "parent_review_commented_without_marker|1|parent_review_commented_without_marker|advance_normal_approved"
  "parent_review_approved_with_bad_json|1|parent_review_approved_with_bad_json|advance_normal_approved"
  "latest_rejected_overrides_old_green|1|parent_review_approved_with_bad_json|advance_normal_approved"
  "selected_changes_requested|1|selected_changes_requested|advance_normal_approved"
  "selected_dismissed|1|selected_dismissed|advance_normal_approved"
  "controller_json_head_mismatch|1|controller_json_head_mismatch|advance_normal_approved"
  "controller_nx_required_false|1|controller_nx_required_false|advance_normal_approved"
  "controller_ready_true|1|controller_ready_true|advance_normal_approved"
  "controller_merge_true|1|controller_merge_true|advance_normal_approved"
  "controller_release_true|1|controller_release_true|advance_normal_approved"
  "controller_review_complete_false|1|controller_review_complete_false|advance_normal_approved"
  "controller_classification_not_green|1|controller_classification_not_green|advance_normal_approved"
  "controller_marker_duplicated_in_body|1|controller_marker_duplicated_in_body|advance_normal_approved"
  "controller_json_blocks_duplicated|1|controller_json_blocks_duplicated|advance_normal_approved"
  "bootstrap_policy_green_without_body_evidence|1|bootstrap_policy_green_without_body_evidence|advance_bootstrap"
  "bootstrap_wrong_review_id|1|bootstrap_review_missing|advance_bootstrap"
  "bootstrap_wrong_commit|1|bootstrap_wrong_commit|advance_bootstrap"
  "bootstrap_wrong_classification|1|bootstrap_policy_green_without_body_evidence|advance_bootstrap"
  "bootstrap_wrong_child|1|head_sha_mismatch|advance_bootstrap"
  "bootstrap_reused_after_r7|1|head_sha_mismatch|advance_bootstrap"
  "repair_wrong_review_id|2|api_404_reviews|advance_repair"
  "repair_wrong_parent|1|latest_rejected_overrides_old_green|advance_repair"
  "repair_wrong_classification|1|repair_wrong_classification|advance_repair"
  "repair_wrong_commit_message|1|repair_wrong_commit_message|advance_repair"
  "repair_wrong_workstream_trailer|1|repair_wrong_workstream_trailer|advance_repair"
  "repair_wrong_decision|1|repair_schema_invalid|advance_repair"
  "repair_wrong_review_state|1|repair_wrong_review_state|advance_repair"
  "repair_malformed_json|1|repair_malformed_json|advance_repair"
  "repair_marker_duplicated|1|repair_marker_duplicated|advance_repair"
  "repair_json_head_mismatch|1|repair_json_head_mismatch|advance_repair"
  "repair_review_incomplete|1|repair_review_incomplete|advance_repair"
  "repair_nx_required_false|1|repair_nx_required_false|advance_repair"
  "repair_unsafe_authorization|1|repair_unsafe_authorization|advance_repair"
  "repair_review_after_child|1|repair_review_after_child|advance_repair"
  "repair_forbidden_path|1|repair_forbidden_path|advance_repair"
  "repair_production_source_changed|1|repair_forbidden_path|advance_repair"
  "repair_merge_commit|1|merge_commit_rejected|advance_repair"
  "repair_reused_after_fix1|1|latest_rejected_overrides_old_green|advance_repair"
  "repair_quarantined_review_used|1|repair_quarantined_review_used|advance_repair"
  "repair_scope_missing|2|repair_scope_invalid|advance_repair"
  "repair_scope_wrong_type_exact|2|repair_scope_invalid|advance_repair"
  "repair_scope_wrong_type_prefix|2|repair_scope_invalid|advance_repair"
  "repair_scope_empty_entry|2|repair_scope_invalid|advance_repair"
  "repair_scope_duplicate|2|repair_scope_invalid|advance_repair"
  "repair_scope_absolute|2|repair_scope_invalid|advance_repair"
  "repair_scope_traversal|2|repair_scope_invalid|advance_repair"
  "repair_scope_prefix_no_slash|2|repair_scope_invalid|advance_repair"
  "repair_scope_outside_envelope|1|repair_scope_outside_safe_envelope|advance_repair"
  "repair_scope_sources_declared|1|repair_scope_outside_safe_envelope|advance_repair"
  "repair_scope_tests_declared|1|repair_scope_outside_safe_envelope|advance_repair"
  "repair_scope_front_file_omitted|1|repair_forbidden_path|advance_repair"
  "repair_scope_gate1_changes_truth_py|1|repair_forbidden_path|advance_repair"
  "repair_scope_gate1_changes_truth_fixtures|1|repair_forbidden_path|advance_repair"
  "repair_scope_tier_a_doc_denied|1|repair_forbidden_path|advance_repair"
  "repair_scope_old_r8_review_id|2|api_404_reviews|advance_repair"
  "red_source_auth_comment_missing|2|fixture_missing|advance_red_parent_source_fix_bridge"
  "red_source_auth_comment_edited|1|red_source_auth_comment_edited|advance_red_parent_source_fix_bridge"
  "red_source_auth_marker_duplicated|1|red_source_auth_marker_duplicated|advance_red_parent_source_fix_bridge"
  "red_source_auth_json_duplicated|1|red_source_auth_json_duplicated|advance_red_parent_source_fix_bridge"
  "red_source_auth_schema_mismatch|1|red_source_auth_schema_mismatch|advance_red_parent_source_fix_bridge"
  "red_source_auth_policy_mismatch|1|red_source_auth_policy_mismatch|advance_red_parent_source_fix_bridge"
  "red_source_auth_unsafe_authorization|1|red_source_auth_unsafe_authorization|advance_red_parent_source_fix_bridge"
  "red_source_fix_wrong_parent|1|red_source_fix_wrong_source_parent|advance_red_parent_source_fix_bridge"
  "red_source_fix_wrong_subject|1|red_source_fix_wrong_subject|advance_red_parent_source_fix_bridge"
  "red_source_fix_wrong_workstream|1|red_source_fix_wrong_workstream|advance_red_parent_source_fix_bridge"
  "red_source_fix_forbidden_path|1|red_source_fix_forbidden_path|advance_red_parent_source_fix_bridge"
  "red_source_fix_no_changed_files|2|red_source_fix_no_changed_files|advance_red_parent_source_fix_bridge"
  "red_source_ci_wrong_sha|1|red_source_ci_wrong_sha|advance_red_parent_source_fix_bridge"
  "red_source_ci_failed|1|red_source_ci_failed|advance_red_parent_source_fix_bridge"
  "red_source_ci_required_job_missing|1|red_source_ci_required_job_missing|advance_red_parent_source_fix_bridge"
  "red_bridge_wrong_subject|1|red_bridge_wrong_subject|advance_red_parent_source_fix_bridge"
  "red_bridge_wrong_workstream|1|red_bridge_wrong_workstream|advance_red_parent_source_fix_bridge"
  "red_bridge_forbidden_path|1|red_bridge_forbidden_path|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_missing|1|red_bridge_rejected_review_missing|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_wrong_id|1|red_bridge_rejected_review_missing|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_wrong_commit|1|red_bridge_rejected_review_wrong_commit|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_wrong_decision|1|red_bridge_rejected_review_wrong_decision|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_wrong_classification|1|red_bridge_rejected_review_wrong_classification|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_incomplete|1|red_bridge_rejected_review_incomplete|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_nx_false|1|red_bridge_rejected_review_nx_false|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_ready_true|1|red_bridge_rejected_review_ready_true|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_merge_true|1|red_bridge_rejected_review_merge_true|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_release_true|1|red_bridge_rejected_review_release_true|advance_red_parent_source_fix_bridge"
  "red_bridge_rejected_review_after_source_fix|1|red_bridge_rejected_review_after_source_fix|advance_red_parent_source_fix_bridge"
  "red_failed_advance_incomplete|1|red_bridge_failed_advance_incomplete|advance_red_parent_source_fix_bridge"
  "red_failed_advance_success|1|red_bridge_failed_advance_not_failed|advance_red_parent_source_fix_bridge"
  "red_failed_advance_job_missing|1|red_bridge_failed_advance_job_missing|advance_red_parent_source_fix_bridge"
  "red_failed_advance_job_success|1|red_bridge_failed_advance_job_not_failed|advance_red_parent_source_fix_bridge"
  "red_failed_advance_guard_missing|1|red_bridge_failed_advance_guard_missing|advance_red_parent_source_fix_bridge"
  "red_failed_advance_guard_mismatch|1|red_bridge_failed_advance_guard_mismatch|advance_red_parent_source_fix_bridge"
  "red_failed_advance_wrong_head|1|red_bridge_failed_advance_wrong_head|advance_red_parent_source_fix_bridge"
  "red_failed_advance_wrong_parent|1|red_bridge_failed_advance_wrong_parent|advance_red_parent_source_fix_bridge"
  "red_source_auth_after_bridge|1|red_source_auth_after_bridge|advance_red_parent_source_fix_bridge"
  "gate_fix_auth_missing|2|fixture_missing|advance_gate_fix_authorization"
  "gate_fix_auth_edited|1|gate_fix_auth_edited|advance_gate_fix_authorization"
  "gate_fix_auth_marker_duplicated|1|gate_fix_auth_marker_duplicated|advance_gate_fix_authorization"
  "gate_fix_auth_json_duplicated|1|gate_fix_auth_json_duplicated|advance_gate_fix_authorization"
  "gate_fix_auth_policy_mismatch|1|gate_fix_auth_policy_mismatch|advance_gate_fix_authorization"
  "gate_fix_auth_after_child|1|gate_fix_authorization_after_child|advance_gate_fix_authorization"
  "gate_fix_wrong_parent|1|gate_fix_wrong_parent|advance_gate_fix_authorization"
  "gate_fix_wrong_subject|1|gate_fix_wrong_subject|advance_gate_fix_authorization"
  "gate_fix_wrong_workstream|1|gate_fix_wrong_workstream|advance_gate_fix_authorization"
  "gate_fix_forbidden_path|1|gate_fix_forbidden_path|advance_gate_fix_authorization"
  "gate_fix_reused_by_grandchild|1|gate_fix_reused_by_grandchild|advance_gate_fix_authorization"
  "gate_fix_ready_true|1|gate_fix_ready_true|advance_gate_fix_authorization"
  "gate_fix_merge_true|1|gate_fix_merge_true|advance_gate_fix_authorization"
  "gate_fix_release_true|1|gate_fix_release_true|advance_gate_fix_authorization"
)

for entry in "${ADVANCE_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard base_fixture <<< "$entry"
  base_dir="${FIXTURE_DIR}/green/${base_fixture}"
  run_fixture_mutation "$mut_name" "advance" "$base_dir" "" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "advance"
done

# Reverse-direction generality: under the fixture-local R9 truth policy (which
# admits only the R9 truth path / truth-fixtures prefix), a gate-only file
# change must be rejected.
run_fixture_mutation "repair_scope_r9_rejects_gate_path" "advance" \
  "${FIXTURE_DIR}/green/r9_truth_scope_admitted" "" || true
assert_rejected_exact "repair_scope_r9_rejects_gate_path" "1" "repair_forbidden_path" "advance/r9-reverse"

# ================================================
# TEST 2b: Fixture mutations — submission phase (worker report) — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Phase (worker report) ==="

SUBMISSION_REPORT_MUTATIONS=(
  "report_missing|1|report_missing"
  "report_malformed_current_head|1|report_malformed_current_head"
  "report_marker_duplicated|1|report_marker_duplicated"
  "report_json_block_duplicated|1|report_marker_duplicated"
  "report_inline|1|report_inline"
  "report_reply|1|report_reply"
  "report_head_mismatch|1|report_missing"
  "report_parent_mismatch|1|report_parent_mismatch"
  "report_commit_count_invalid|1|report_commit_count_invalid"
  "report_workstream_mismatch|1|report_workstream_mismatch"
  "head_commit_message_missing|2|head_commit_message_missing"
  "head_workstream_trailer_missing|1|head_workstream_trailer_missing"
  "head_workstream_trailer_duplicated|1|head_workstream_trailer_duplicated"
  "head_workstream_trailer_invalid|1|head_workstream_trailer_invalid"
  "report_stop_false|1|report_stop_false"
  "report_next_workstream_true|1|report_next_workstream_started"
  "report_ready_true|1|report_unsafe_action"
  "report_merge_true|1|report_unsafe_action"
  "report_release_true|1|report_unsafe_action"
  "report_before_commit|1|report_missing"
  "report_bool_used_as_integer|1|report_extra_property"
  "report_duplicate_ci_jobs|1|report_extra_property"
  "report_invalid_array_item|1|report_extra_property"
  "report_extra_property|1|report_extra_property"
  "duplicate_current_head_reports|1|duplicate_current_head_reports"
  "report_submission_run_numeric|1|report_extra_property"
  "report_submission_run_string|1|report_extra_property"
  "report_submission_run_missing|1|report_extra_property"
  "report_submission_run_id_non_null|1|report_extra_property"
  "report_gate_submission_run_id_numeric|1|report_extra_property"
  "report_gate_submission_run_id_string|1|report_extra_property"
  "report_gate_submission_run_id_missing|1|report_extra_property"
  "ci_run_missing|1|ci_run_missing"
  "ci_run_wrong_head|1|ci_run_wrong_head"
  "ci_run_wrong_workflow|1|ci_run_wrong_workflow"
  "ci_run_incomplete|1|ci_run_incomplete"
  "ci_run_failed|1|ci_run_not_success"
  "ci_job_missing|1|ci_job_missing"
  "ci_job_failed|1|ci_job_failed"
  "ci_job_duplicate|1|ci_job_duplicate"
  "pagination_parse_failure|2|fixture_json_malformed"
  "pagination_page_type_invalid|2|object_unparseable"
  "pagination_duplicate_id|2|pagination_duplicate_id"
  "api_404_comments|2|fixture_missing"
  "api_404_runs|2|fixture_missing"
  "api_404_jobs|2|fixture_missing"
  "fixture_missing_comments|2|fixture_missing"
  "fixture_missing_runs|2|fixture_missing"
  "fixture_missing_jobs|2|fixture_missing"
)

for entry in "${SUBMISSION_REPORT_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard <<< "$entry"
  run_fixture_mutation "$mut_name" "submission" "${FIXTURE_DIR}/green/submission_historical_reports" "--worker-report-comment-id 5161887211" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "submission"
done

# --- FIX1: replay isolation mutations (base: submission_exact_comment_id) ---
REPLAY_MUTATIONS=(
  "replay_malformed_marker_at_or_after_head|1|report_json_block_duplicated"
  "replay_malformed_json_at_or_after_head|1|report_malformed_current_head"
  "replay_historical_marker_missing_timestamp|2|object_unparseable"
  "replay_historical_marker_malformed_timestamp|2|timestamp_malformed"
  "replay_duplicate_valid_current_head_reports|1|duplicate_current_head_reports"
  "replay_selected_exact_report_malformed|1|report_malformed_current_head"
)

for entry in "${REPLAY_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard <<< "$entry"
  run_fixture_mutation "$mut_name" "submission" "${FIXTURE_DIR}/green/submission_exact_comment_id" "--worker-report-comment-id 5161887211" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "submission/replay"
done

# ================================================
# TEST 2c: Fixture mutations — submission phase (run receipt) — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Run Receipt ==="

SUBMISSION_RECEIPT_MUTATIONS=(
  "submission_run_wrong_head|1|submission_run_wrong_head"
  "submission_run_wrong_branch|1|submission_run_wrong_branch"
  "submission_run_wrong_event|1|submission_run_wrong_event"
  "submission_run_wrong_phase_in_name|1|receipt_display_title_wrong_phase"
  "submission_run_wrong_pr_in_name|1|receipt_display_title_wrong_pr"
  "submission_run_wrong_report_id_in_name|1|receipt_display_title_wrong_report"
  "submission_run_wrong_head_in_name|1|receipt_display_title_wrong_head"
  "submission_run_attempt_gt_one|1|submission_run_attempt_gt_one"
  "submission_run_incomplete|1|submission_run_incomplete"
  "submission_run_failed|1|submission_run_failed"
  "submission_run_wrong_id|1|submission_run_missing"
  "submission_run_id_mismatch|1|submission_run_missing"
  "report_created_after_submission_run|1|report_missing"
  "submission_completed_after_review|1|review_before_report"
)

for entry in "${SUBMISSION_RECEIPT_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard <<< "$entry"
  run_fixture_mutation "$mut_name" "review" "${FIXTURE_DIR}/green/review_exact_submission_receipt" "--worker-report-comment-id 5161887211" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "review/submission-receipt"
done

# ================================================
# TEST 2d: Fixture mutations — submission gate job — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Gate Job ==="

SUBMISSION_JOB_MUTATIONS=(
  "submission_gate_job_missing|1|receipt_submission_job_missing"
  "submission_gate_job_failed|1|submission_gate_job_failed"
  "submission_gate_job_skipped|1|submission_gate_job_skipped"
  "submission_gate_job_cancelled|1|submission_gate_job_cancelled"
  "submission_gate_job_duplicate|1|receipt_submission_job_duplicate"
)

for entry in "${SUBMISSION_JOB_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard <<< "$entry"
  run_fixture_mutation "$mut_name" "review" "${FIXTURE_DIR}/green/review_exact_submission_receipt" "--worker-report-comment-id 5161887211" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "review/submission-job"
done

# ================================================
# TEST 2e: Fixture mutations — submission run infra — should fail (exit 2)
# ================================================
echo ""
echo "=== Fixture Mutations: Submission Run Infrastructure ==="

SUBMISSION_INFRA_MUTATIONS=(
  "api_404_submission_runs|1|submission_run_missing"
  "api_404_submission_jobs|1|receipt_submission_job_missing"
  "submission_runs_json_malformed|2|fixture_json_malformed"
  "submission_jobs_json_malformed|2|fixture_json_malformed"
  "submission_runs_page_type_invalid|1|submission_run_missing"
  "submission_runs_duplicate_id|2|submission_runs_duplicate_id"
  "submission_job_id_non_integer|2|submission_job_id_non_integer"
  "fixture_missing_submission_runs|1|submission_run_missing"
  "fixture_missing_submission_jobs|1|receipt_submission_job_missing"
  "fixture_missing_submission_comment|2|fixture_missing"
)

for entry in "${SUBMISSION_INFRA_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard <<< "$entry"
  run_fixture_mutation "$mut_name" "submission" "${FIXTURE_DIR}/green/submission_exact_comment_id" "--worker-report-comment-id 5161887211" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "submission/infra"
done

# ================================================
# TEST 2f: Fixture mutations — controller review receipt — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: Controller Review Receipt ==="

CONTROLLER_RECEIPT_MUTATIONS=(
  "controller_worker_report_comment_id_missing|1|parent_review_approved_with_bad_json"
  "controller_submission_run_id_missing|1|parent_review_approved_with_bad_json"
  "controller_worker_report_comment_id_zero|1|parent_review_approved_with_bad_json"
  "controller_submission_run_id_zero|1|parent_review_approved_with_bad_json"
  "controller_worker_report_comment_id_string|1|parent_review_approved_with_bad_json"
  "controller_submission_run_id_string|1|parent_review_approved_with_bad_json"
  "controller_receipt_wrong_comment_id|1|receipt_display_title_wrong_report"
  "controller_receipt_wrong_submission_run_id|1|submission_run_missing"
)

for entry in "${CONTROLLER_RECEIPT_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard <<< "$entry"
  run_fixture_mutation "$mut_name" "review" "${FIXTURE_DIR}/green/review_commented_accepted_with_receipt" "--worker-report-comment-id 5161887211" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "review/controller-receipt"
done

# ================================================
# TEST 2g: Fixture mutations — remaining infra/PR — should fail
# ================================================
echo ""
echo "=== Fixture Mutations: PR / Policy / Infra ==="

PR_POLICY_MUTATIONS=(
  "repository_mismatch|1|repository_mismatch|advance_normal_approved"
  "pr_number_mismatch|1|pr_number_mismatch|advance_normal_approved"
  "head_branch_mismatch|1|head_branch_mismatch|advance_normal_approved"
  "base_branch_mismatch|1|base_branch_mismatch|advance_normal_approved"
  "pr_closed|1|pr_closed|advance_normal_approved"
  "pr_not_draft|1|pr_not_draft|advance_normal_approved"
  "pr_merged|1|pr_merged|advance_normal_approved"
  "pr_not_mergeable|1|pr_not_mergeable|advance_normal_approved"
  "expected_head_invalid|1|pr_number_mismatch|advance_normal_approved"
  "policy_missing|1|_EMPTY_|advance_normal_approved"
  "policy_malformed|1|_EMPTY_|advance_normal_approved"
  "timestamp_malformed|2|timestamp_malformed|advance_normal_approved"
  "commit_parent_missing|1|merge_commit_rejected|advance_normal_approved"
  "mergeable_unknown_after_retry|2|mergeable_unknown_after_retry|advance_normal_approved"
  "merge_commit_rejected|1|merge_commit_rejected|advance_normal_approved"
  "api_404_pr|2|fixture_missing|advance_normal_approved"
  "api_404_commit|2|fixture_missing|advance_normal_approved"
  "api_404_reviews|2|fixture_missing|advance_normal_approved"
  "fixture_missing_reviews|2|fixture_missing|advance_normal_approved"
  "fixture_missing_pr|2|fixture_missing|advance_normal_approved"
  "fixture_missing_commit|2|fixture_missing|advance_normal_approved"
  "fixture_json_malformed|2|fixture_json_malformed|advance_normal_approved"
)

for entry in "${PR_POLICY_MUTATIONS[@]}"; do
  IFS='|' read -r mut_name expected_rc expected_guard base_fixture <<< "$entry"
  base_dir="${FIXTURE_DIR}/green/${base_fixture}"
  run_fixture_mutation "$mut_name" "advance" "$base_dir" "" || true
  assert_rejected_exact "$mut_name" "$expected_rc" "$expected_guard" "advance/pr-policy"
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
  "bridge_policy_read_as_scope_authority|advance_red_parent_source_fix_bridge|advance|"
  "bridge_drop_source_scope_check|advance_red_parent_source_fix_bridge|advance|"
  "bypass_rejected_review_fetch|advance_red_parent_source_fix_bridge|advance|"
  "bypass_rejected_review_classification_check|advance_red_parent_source_fix_bridge|advance|"
  "bypass_failed_advance_conclusion|advance_red_parent_source_fix_bridge|advance|"
  "bypass_failed_advance_job_check|advance_red_parent_source_fix_bridge|advance|"
  "bypass_failed_advance_guard_check|advance_red_parent_source_fix_bridge|advance|"
  "bypass_source_auth_chronology|advance_red_parent_source_fix_bridge|advance|"
  "gate_fix_scope_read_from_policy|advance_gate_fix_authorization|advance|"
  "gate_fix_chronology_bypassed|advance_gate_fix_authorization|advance|"
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
# The gate must never add or modify any production source. Any delta under
# Sources/ or Tests/ is a FAIL (no whitelist). The canonical harness is run in
# a detached isolated worktree that contains no product WIP.
if git -C "$WORKTREE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  CHANGED=$(git -C "$WORKTREE_DIR" diff --name-only -- Sources Tests 2>/dev/null || true)
  if [ -n "$CHANGED" ]; then
    bad "Production source files modified (Sources/ or Tests/): $CHANGED"
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
