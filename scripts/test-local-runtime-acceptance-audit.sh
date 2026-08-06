#!/usr/bin/env bash
# test-local-runtime-acceptance-audit.sh — U1R18-R11 acceptance audit harness.
#
# Exercises scripts/local-runtime-acceptance-audit.py against fixture repos.
# Each fixture begins from base/ committed at HEAD, then applies the fixture's
# overlay(s) to the working tree exactly like the production audit sees it.
#
#   rc 0  = clean contract (GREEN)
#   rc 1  = semantic violation (e.g. immutable-scope mutation, redaction leak)
#   rc 2  = infrastructure failure (missing required file/declaration)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PY="scripts/local-runtime-acceptance-audit.py"
FIX="scripts/local-runtime-acceptance-fixtures"
BASE="$FIX/base"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# build <fixture-dir> -> new temp git repo seeded from base (committed at HEAD),
# then overlays the fixture files onto the working tree (unstaged, as the
# audit's immutable check compares working tree vs HEAD).
build() {
    local src="$1"
    local dir="$TMP/$(basename "$src")"
    rm -rf "$dir"
    cp -R "$BASE" "$dir"
    (cd "$dir" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm seed)
    if [ -f "$src/overlay-paths.txt" ]; then
        local rel
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            rm -f "$dir/$rel"
        done < "$src/overlay-paths.txt"
    fi
    local f
    while IFS= read -r -d '' f; do
        local rel="${f#"$src"/}"
        case "$rel" in
            overlay-paths.txt) continue ;;
        esac
        local dst="$dir/$rel"
        mkdir -p "$(dirname "$dst")"
        cp "$f" "$dst"
    done < <(find "$src" -type f -print0)
    echo "$dir"
}

# run <fixture-name> <label> <expected_rc> [guard-substring]
run() {
    local name="$1" label="$2" exp="$3" guard="${4:-}"
    local dir rc out
    dir="$(build "$FIX/$name" "ass-$name")" || { bad "$label: build failed"; return; }
    set +e
    out=$(python3 "$PY" --repo-root "$dir" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq "$exp" ]; then
        if [ -n "$guard" ] && ! echo "$out" | grep -qF "$guard"; then
            bad "$label (expected '$guard' absent in: $(echo "$out"|tr '\n' ' '))"
        else
            ok "$label"
        fi
    else
        bad "$label (rc=$rc want $exp)"
    fi
}

echo "=== Local runtime acceptance audit harness ==="

echo "--- GREEN ---"
run "green"            "clean contract passes" 0
run "green-noop" "clean contract with unrelated overlay" 0

echo "--- RED: immutable-scope mutation (rc=1) ---"
run "red-session-mutated" "supervisor mutated" 1 "immutable scope changed"
run "red-receipt-path-leak" "receipt leaks raw path" 1 "prefixRoot"
run "red-receipt-pid-leak" "receipt leaks raw pid" 1 "rootPID"

echo "--- RED: redaction leak (rc=1) ---"
run "red-receipt-uuid-leak" "receipt leaks raw uuid" 1 "uuidString"
run "red-receipt-sessionid-leak" "receipt leaks raw session id" 1 "sessionID"
run "red-receipt-error-leak" "receipt leaks raw error" 1 "localizedDescription"
run "red-receipt-pid-leak2" "receipt leaks process identifier" 1 "processIdentifier"

echo "--- RED: infrastructure (rc=2) ---"
run "red-authority-missing" "authority file removed" 2 "required contract missing"
run "red-requirecompletion-absent" "requireCompletion removed" 2 "requireCompletion"
run "red-authority-statefield-missing" "authority state property absent" 2 "required contract missing"
run "red-prereq-source-missing" "prereq source gate removed" 2 "required contract missing"
run "red-prereq-health-missing" "prereq health gate removed" 2 "required contract missing"
run "red-prereq-prefix-missing" "prereq prefix gate removed" 2 "required contract missing"
run "red-prereq-steam-missing" "prereq steam gate removed" 2 "required contract missing"
run "red-prereq-cloverpit-missing" "prereq cloverpit gate removed" 2 "required contract missing"
run "red-authority-observe-absent" "authority observe removed" 2 "required contract missing"
run "red-authority-begin-absent" "authority begin removed" 2 "required contract missing"
run "red-authority-stability-absent" "authority stability removed" 2 "required contract missing"
run "red-authority-current-absent" "authority currentReceipt removed" 2 "required contract missing"

echo "--- RED: FIX1 invariant (rc=1) ---"
run "red-view-input-action-missing" "input-confirm action removed" 1 "confirmInputResponse"
run "red-view-panel-hidden-after-launch-result" "acceptance UI hides after launch result" 1 "acceptancePanel"
run "red-receipt-built-before-accepted-state" "receipt built before accepted state" 1 "ordering"
run "red-success-discards-authority" "success invalidates/discards authority" 1 "cancelLocalAcceptanceObservationPreservingAuthority"
run "red-ownership-derived-from-visibility" "ownership derived from visibility" 1 "ownershipCensusProven"

echo "--- GREEN variants ---"
run "green-variant-space" "green space variant" 0
run "green-variant-comment" "green comment variant" 0
run "green-variant-rename-local" "green local-name variant" 0
run "green-variant-emoji" "green emoji variant" 0
run "green-variant-tabs" "green tabs variant" 0
run "green-variant-case" "green case variant" 0

echo ""
echo "=== Acceptance harness summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0