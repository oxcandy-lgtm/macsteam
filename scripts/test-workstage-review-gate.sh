#!/usr/bin/env bash
set -euo pipefail

# Workstream Review Gate — Mutation Fixture Test Harness — U1R18-R7
#
# Verifies:
#   1. Gate script compiles (Python syntax valid)
#   2. All GREEN fixtures pass
#   3. Each mutation produces the expected guard failure with exact label
#   4. No unrelated syntax errors or different-guard failures
#   5. Caller worktree remains unchanged

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/workstage-review-gate.py"
POLICY_FILE="$REPO_ROOT/.github/workstage-review-gate-policy.json"
FIXTURES_ROOT="$SCRIPT_DIR/workstage-review-gate-fixtures"
MUTATOR="$FIXTURES_ROOT/apply-mutation.py"

cd "$REPO_ROOT"

PASS=0
FAIL=0
TOTAL=0

HEAD_NORMAL="dad91d9ea3a6338b795f1472d0e4f729a1e419db"
HEAD_BOOTSTRAP="cafe1234cafe1234cafe1234cafe1234cafe1234"

echo "=== Workstream Review Gate — Mutation Harness ==="
echo ""

# --- Pre-check ---
echo "=== Pre-check: Python compilation ==="
if python3 -m py_compile "$GATE_SCRIPT" 2>/dev/null; then
    echo "[PASS] Gate script compiles"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
else
    echo "[FAIL] Gate script does not compile"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
fi

if python3 -m py_compile "$MUTATOR" 2>/dev/null; then
    echo "[PASS] Mutator compiles"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
else
    echo "[FAIL] Mutator does not compile"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
fi
echo ""

# --- GREEN fixtures must pass ---
echo "=== GREEN Fixture Verification ==="
echo ""

green_pass() {
    local name="$1" phase="$2" head="$3" dir="$4"
    TOTAL=$((TOTAL + 1))
    local output rc=0
    output=$(python3 "$GATE_SCRIPT" --phase "$phase" --pr-number 2 \
        --expected-head "$head" --fixtures "$dir" --policy "$POLICY_FILE" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[PASS] $name (GREEN)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name (GREEN): exit $rc, expected 0"
        echo "  $(echo "$output" | tail -1)" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
}

green_pass "advance_normal" "advance" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/advance_normal"
green_pass "advance_bootstrap" "advance" "$HEAD_BOOTSTRAP" \
    "$FIXTURES_ROOT/green/advance_bootstrap"
green_pass "submission" "submission" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/submission"
green_pass "review" "review" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/review"

echo ""

# --- Mutation tests ---
echo "=== Mutation Fixture Tests ==="
echo ""

# Snapshot worktree before mutations
HEAD_BEFORE=$(git rev-parse HEAD)
PORCELAIN_BEFORE=$(git status --porcelain)

run_mutation() {
    local label="$1" phase="$2" head="$3" src="$4"
    local mut_name="$5" exp_exit="$6" exp_guard="$7"

    TOTAL=$((TOTAL + 1))
    echo "--- $label ---"

    local temp_dir
    temp_dir=$(mktemp -d)
    cp "$src"/*.json "$temp_dir/" 2>/dev/null || true

    # Apply mutation
    if ! python3 "$MUTATOR" "$mut_name" "$temp_dir" 2>/dev/null; then
        echo "[FAIL] $label: mutator execution failed"
        rm -rf "$temp_dir"
        FAIL=$((FAIL + 1))
        return
    fi

    # Run gate script
    local output rc=0
    output=$(python3 "$GATE_SCRIPT" --phase "$phase" --pr-number 2 \
        --expected-head "$head" --fixtures "$temp_dir" --policy "$POLICY_FILE" 2>&1) || rc=$?

    rm -rf "$temp_dir"

    if [ "$rc" -ne "$exp_exit" ]; then
        echo "[FAIL] $label: exit=$rc, expected=$exp_exit"
        echo "  $(echo "$output" | tail -1)" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        return
    fi

    local actual_guard
    actual_guard=$(echo "$output" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); print(d.get('guard_label',''))
except: print('')
" 2>/dev/null) || actual_guard=""

    if [ "$actual_guard" != "$exp_guard" ]; then
        echo "[FAIL] $label: guard='$actual_guard', expected='$exp_guard'"
        echo "  $(echo "$output" | tail -1)" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        return
    fi

    echo "[PASS] $label"
    PASS=$((PASS + 1))
}

run_mutation "M1_parent_review_removed" "advance" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/advance_normal" "M1" \
    1 "parent_review_missing"

run_mutation "M2_review_commit_id_wrong" "advance" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/advance_normal" "M2" \
    1 "parent_review_wrong_head"

run_mutation "M3_worker_report_removed" "submission" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/submission" "M3" \
    1 "report_missing"

run_mutation "M4_stop_flag_false" "submission" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/submission" "M4" \
    1 "stop_flag_false"

run_mutation "M5_merge_commit" "advance" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/advance_normal" "M5" \
    1 "merge_commit_rejected"

run_mutation "M6_ci_run_wrong_head" "submission" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/submission" "M6" \
    1 "ci_run_wrong_head"

run_mutation "M7_job_failed" "submission" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/submission" "M7" \
    1 "ci_job_failed"

run_mutation "M8_review_before_report" "review" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/review" "M8" \
    1 "review_before_report"

run_mutation "M9_newer_red_review" "review" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/review" "M9" \
    1 "newer_red_review_overrides"

run_mutation "M10_bootstrap_review_removed" "advance" "$HEAD_BOOTSTRAP" \
    "$FIXTURES_ROOT/green/advance_bootstrap" "M10" \
    1 "bootstrap_review_missing"

run_mutation "M11_draft_false" "advance" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/advance_normal" "M11" \
    1 "pr_state_mismatch"

run_mutation "M12_api_data_removed" "advance" "$HEAD_NORMAL" \
    "$FIXTURES_ROOT/green/advance_normal" "M12" \
    2 "fixture_missing"

echo ""

# --- Summary ---
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL  Total: $TOTAL"

# --- Verify worktree unchanged ---
HEAD_AFTER=$(git rev-parse HEAD)
PORCELAIN_AFTER=$(git status --porcelain)

if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    echo "[FAIL] HEAD changed: $HEAD_BEFORE -> $HEAD_AFTER"
    FAIL=$((FAIL + 1))
elif [ "$PORCELAIN_AFTER" != "$PORCELAIN_BEFORE" ]; then
    echo "[FAIL] Worktree became dirty:"
    echo "$PORCELAIN_AFTER" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
else
    echo "[PASS] Worktree unchanged"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL test(s) failed."
    exit 1
fi
echo "All workshift review gate fixtures passed."
