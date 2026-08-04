#!/usr/bin/env bash
# test-u1r18-pr-truth.sh — U1R18 canonical PR truth authority harness
#
# Exercises scripts/u1r18-pr-truth.py against the fixture tree. Every RED
# mutation asserts the exact exit code AND the exact guard label. The harness
# self-checks its own mapping: a fixture without a mapping, a mapping without
# a fixture, an empty fixture, or two byte-identical fixtures is a FAIL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PY="scripts/u1r18-pr-truth.py"
FIX="scripts/u1r18-pr-truth-fixtures"
GREEN="$FIX/green"
RED="$FIX/red"
STATE="$GREEN/final-r9-state.json"
BODY="$GREEN/stale-r7-body.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()  { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# run <desc> <expected_rc> <expected_guard> -- cmd...
run() {
    local desc="$1" exp_rc="$2" exp_guard="$3"
    shift 3
    [ "$1" = "--" ] && shift
    local rc guard
    set +e
    "$@" >"$TMP/out" 2>"$TMP/err"
    rc=$?
    set -e
    guard=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("guard",""))
except Exception:
    print("")' "$TMP/err" 2>/dev/null || true)
    if [ "$rc" -eq "$exp_rc" ] && [ "$guard" = "$exp_guard" ]; then
        ok "$desc"
    else
        bad "$desc (rc=$rc exp=$exp_rc guard='$guard' exp='$exp_guard')"
    fi
}

echo "=== U1R18 canonical PR truth authority ==="
echo "--- toolchain prerequisites ---"

for f in "$PY" "Contracts/u1r18-canonical-state.schema.json"; do
    if [ -f "$f" ]; then
        ok "prerequisite exists: $f"
    else
        bad "prerequisite missing: $f"
    fi
done

echo "--- GREEN: state validation ---"
run "green state validate-state rc=0" 0 "" -- python3 "$PY" validate-state --state "$STATE"

echo "--- GREEN: body inspection ---"
python3 "$PY" inspect-body --body "$BODY" >"$TMP/inspect.json" 2>"$TMP/err" || bad "inspect-body failed"
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["marker_count"]==1, d
assert d["sentinel_count"]==1, d
assert d["canonical_head_found"]=="90fb379d03ed71bd2c07f73a27f77551a79bee88", d
assert d["stale_r8_defined_false_found"] is True, d
assert d["historical_suffix_digest"], d
' "$TMP/inspect.json"; then
    ok "green inspect-body fields correct"
else
    bad "green inspect-body fields incorrect"
fi

echo "--- GREEN: deterministic render + verify ---"
python3 "$PY" render --state "$STATE" --body "$BODY" --output "$TMP/r1.md" \
    >/dev/null 2>"$TMP/err" || bad "render #1 failed"
python3 "$PY" render --state "$STATE" --body "$BODY" --output "$TMP/r2.md" \
    >/dev/null 2>"$TMP/err" || bad "render #2 failed"
if cmp -s "$TMP/r1.md" "$TMP/r2.md"; then
    ok "render twice byte-identical"
else
    bad "render twice NOT byte-identical"
fi
run "green verify-render rc=0" 0 "" -- python3 "$PY" verify-render --state "$STATE" --before "$BODY" --after "$TMP/r1.md"

echo "--- GREEN: output contract ---"
MC=$(grep -c 'macsteam-u1r18-canonical-state:v1' "$TMP/r1.md" || true)
SC=$(grep -c 'Everything below this canonical block is retained' "$TMP/r1.md" || true)
R5=$(grep -c 'R5 external real-Mac proof requirement was removed by product-owner decision' "$TMP/r1.md" || true)
[ "$MC" -eq 1 ] && ok "output marker exactly 1" || bad "output marker count=$MC"
[ "$SC" -eq 1 ] && ok "output sentinel exactly 1" || bad "output sentinel count=$SC"
[ "$R5" -eq 1 ] && ok "output R5 sentence exactly 1" || bad "output R5 sentence count=$R5"
grep -q 'id: R8' "$TMP/r1.md" && ok "output contains R8" || bad "output missing R8"
grep -q 'id: R9' "$TMP/r1.md" && ok "output contains R9" || bad "output missing R9"
grep -q 'state: CLOSED' "$TMP/r1.md" && ok "output contains CLOSED states" || bad "output missing CLOSED"

echo "--- GREEN: historical suffix preservation ---"
if python3 -c '
import hashlib,sys
def suffix(p):
    MARKER="<!-- macsteam-u1r18-canonical-state:v1 -->"
    SENT=("Everything below this canonical block is retained as historical "
          "development context and may reference superseded commits, CI runs, "
          "intermediate classifications, or earlier pending work.")
    b=open(p,encoding="utf-8").read()
    s=b.find(SENT); e=s+len(SENT)
    if b[e:e+1]=="\n": e+=1
    return b[e:]
a=suffix(sys.argv[1]); b=suffix(sys.argv[2])
print("before_digest=",hashlib.sha256(a.encode()).hexdigest())
print("after_digest=",hashlib.sha256(b.encode()).hexdigest())
assert a==b, "suffix changed"
' "$BODY" "$TMP/r1.md" >"$TMP/digest.txt"; then
    ok "historical suffix byte-identical"
else
    bad "historical suffix changed"
fi
if grep -q '過去の補足' "$TMP/r1.md"; then
    ok "UTF-8 Japanese history preserved"
else
    bad "Japanese history lost"
fi
if grep -q '30449092003' "$TMP/r1.md" && grep -q '90fb379d03ed71bd2c07f73a27f77551a79bee88' "$TMP/r1.md"; then
    ok "old run ID and old SHA preserved in history"
else
    bad "old run ID / old SHA lost"
fi

echo "--- RED: state mutations (validate-state) ---"
run "red state-malformed-json" 2 "state_json_parse_error" -- python3 "$PY" validate-state --state "$RED/state-malformed-json.json"
run "red state-schema-version-mismatch" 1 "state_schema_invalid" -- python3 "$PY" validate-state --state "$RED/state-schema-version-mismatch.json"
run "red state-invalid-sha" 1 "state_head_invalid" -- python3 "$PY" validate-state --state "$RED/state-invalid-sha.json"
run "red state-duplicate-workstream-id" 1 "state_semantic_invalid" -- python3 "$PY" validate-state --state "$RED/state-duplicate-workstream-id.json"
run "red state-workstream-order-violation" 1 "state_semantic_invalid" -- python3 "$PY" validate-state --state "$RED/state-workstream-order-violation.json"
run "red state-receipt-id-zero" 1 "state_semantic_invalid" -- python3 "$PY" validate-state --state "$RED/state-receipt-id-zero.json"
run "red state-ready-authorized" 1 "unsafe_authorization" -- python3 "$PY" validate-state --state "$RED/state-ready-authorized.json"
run "red state-merge-authorized" 1 "unsafe_authorization" -- python3 "$PY" validate-state --state "$RED/state-merge-authorized.json"
run "red state-release-authorized" 1 "unsafe_authorization" -- python3 "$PY" validate-state --state "$RED/state-release-authorized.json"
run "red state-next-workstream-admitted" 1 "unsafe_authorization" -- python3 "$PY" validate-state --state "$RED/state-next-workstream-admitted.json"
run "red state-r5-proof-performed" 1 "state_semantic_invalid" -- python3 "$PY" validate-state --state "$RED/state-r5-proof-performed.json"
run "red state-r5-proof-claimed" 1 "state_semantic_invalid" -- python3 "$PY" validate-state --state "$RED/state-r5-proof-claimed.json"
run "red state-pr-mergeable-false" 1 "state_pr_mergeable_invalid" -- python3 "$PY" validate-state --state "$RED/state-pr-mergeable-false.json"
run "red state-review-final-state-wrong" 1 "state_review_final_state_invalid" -- python3 "$PY" validate-state --state "$RED/state-review-final-state-wrong.json"
run "red state-worker-report-valid-false" 1 "state_worker_report_valid_invalid" -- python3 "$PY" validate-state --state "$RED/state-worker-report-valid-false.json"
run "red state-controller-review-valid-false" 1 "state_controller_review_valid_invalid" -- python3 "$PY" validate-state --state "$RED/state-controller-review-valid-false.json"
run "red state-nx-required-false" 1 "state_nx_required_invalid" -- python3 "$PY" validate-state --state "$RED/state-nx-required-false.json"
run "red state-gate-advance-state-wrong" 1 "state_gate_advance_state_invalid" -- python3 "$PY" validate-state --state "$RED/state-gate-advance-state-wrong.json"
run "red state-gate-parent-authority-wrong" 1 "state_gate_parent_authority_invalid" -- python3 "$PY" validate-state --state "$RED/state-gate-parent-authority-wrong.json"

echo "--- RED: body mutations (render) ---"
run "red body-marker-missing" 1 "body_marker_missing" -- python3 "$PY" render --state "$STATE" --body "$RED/body-marker-missing.md" --output "$TMP/x.md"
run "red body-marker-duplicate" 1 "body_marker_duplicated" -- python3 "$PY" render --state "$STATE" --body "$RED/body-marker-duplicate.md" --output "$TMP/x.md"
run "red body-sentinel-missing" 1 "body_sentinel_missing" -- python3 "$PY" render --state "$STATE" --body "$RED/body-sentinel-missing.md" --output "$TMP/x.md"
run "red body-sentinel-duplicate" 1 "body_sentinel_duplicated" -- python3 "$PY" render --state "$STATE" --body "$RED/body-sentinel-duplicate.md" --output "$TMP/x.md"
run "red body-sentinel-before-marker" 1 "body_order_invalid" -- python3 "$PY" render --state "$STATE" --body "$RED/body-sentinel-before-marker.md" --output "$TMP/x.md"

echo "--- RED: verify-render mutations ---"
run "red after-suffix-changed" 1 "historical_suffix_changed" -- python3 "$PY" verify-render --state "$STATE" --before "$BODY" --after "$RED/after-suffix-changed.md"
run "red after-output-marker-duplicate" 1 "output_marker_count_invalid" -- python3 "$PY" verify-render --state "$STATE" --before "$BODY" --after "$RED/after-output-marker-duplicate.md"

echo "--- harness mapping self-check ---"
# Every RED fixture must have a mapping; every mapping must have a fixture.
MISSING_MAP=0
for f in "$RED"/*; do
    name=$(basename "$f")
    case "$name" in
        state-malformed-json.json|state-schema-version-mismatch.json|state-invalid-sha.json|state-duplicate-workstream-id.json|state-workstream-order-violation.json|state-receipt-id-zero.json|state-ready-authorized.json|state-merge-authorized.json|state-release-authorized.json|state-next-workstream-admitted.json|state-r5-proof-performed.json|state-r5-proof-claimed.json|state-pr-mergeable-false.json|state-review-final-state-wrong.json|state-worker-report-valid-false.json|state-controller-review-valid-false.json|state-nx-required-false.json|state-gate-advance-state-wrong.json|state-gate-parent-authority-wrong.json|body-marker-missing.md|body-marker-duplicate.md|body-sentinel-missing.md|body-sentinel-duplicate.md|body-sentinel-before-marker.md|after-suffix-changed.md|after-output-marker-duplicate.md)
            ;;
        *)
            bad "RED fixture without mapping: $name"
            MISSING_MAP=1
            ;;
    esac
done
[ "$MISSING_MAP" -eq 0 ] && ok "every RED fixture has a mapping"

# No orphan mapping: every expected mutation name must have a fixture file.
ORPHAN=0
for name in state-malformed-json.json state-schema-version-mismatch.json state-invalid-sha.json state-duplicate-workstream-id.json state-workstream-order-violation.json state-receipt-id-zero.json state-ready-authorized.json state-merge-authorized.json state-release-authorized.json state-next-workstream-admitted.json state-r5-proof-performed.json state-r5-proof-claimed.json state-pr-mergeable-false.json state-review-final-state-wrong.json state-worker-report-valid-false.json state-controller-review-valid-false.json state-nx-required-false.json state-gate-advance-state-wrong.json state-gate-parent-authority-wrong.json body-marker-missing.md body-marker-duplicate.md body-sentinel-missing.md body-sentinel-duplicate.md body-sentinel-before-marker.md after-suffix-changed.md after-output-marker-duplicate.md; do
    if [ ! -f "$RED/$name" ]; then
        bad "orphan mapping without fixture: $name"
        ORPHAN=1
    fi
done
[ "$ORPHAN" -eq 0 ] && ok "no orphan mapping"

# No empty fixtures.
EMPTY=0
for f in "$GREEN"/* "$RED"/*; do
    if [ ! -s "$f" ]; then
        bad "empty fixture: $f"
        EMPTY=1
    fi
done
[ "$EMPTY" -eq 0 ] && ok "no empty fixtures"

# No byte-identical duplicate fixtures.
DUP=0
prev=""
for h in $(cd "$FIX" && find green red -type f | sort | while read -r f; do shasum -a 256 "$f"; done | cut -d' ' -f1); do
    if [ "$h" = "$prev" ]; then
        bad "duplicate fixture content detected"
        DUP=1
    fi
    prev="$h"
done
[ "$DUP" -eq 0 ] && ok "no duplicate fixtures"

echo ""
echo "=== U1R18 harness summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
