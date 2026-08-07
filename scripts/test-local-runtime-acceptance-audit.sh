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

echo "--- RED: FIX1/R12 invariants (rc=1) ---"
run "red-view-input-action-missing" "input-confirm action removed" 1 "confirmInputResponse"
run "red-view-panel-hidden-after-launch-result" "acceptance UI hides after launch result" 1 "acceptancePanel"
run "red-completion-skips-persist" "completion persists never" 1 "never persists"
run "red-persist-before-cleanup" "persistence before cleanup" 1 "before cleanup"
run "red-persist-failure-still-accepted" "persistence failure still accepted" 1 "not gated"
run "red-persist-called-twice" "persistence called twice" 1 "more than once"
run "red-success-discards-authority" "success invalidates/discards authority" 1 "cancelLocalAcceptanceObservationPreservingAuthority"
run "red-ownership-derived-from-visibility" "ownership derived from visibility" 1 "ownershipCensusProven"
run "red-store-allows-nonaccepted" "store saves non-accepted" 1 "store contract missing"
run "red-store-allows-incomplete-evidence" "store saves incomplete evidence" 1 "store contract missing"
run "red-store-allows-security-true" "store saves security-set" 1 "store contract missing"
run "red-store-follows-symlink" "store follows symlink" 1 "store contract missing"
run "red-store-world-readable" "store file world readable" 1 "must not use world-readable"
run "red-load-promotes-current-state" "historical load promotes current state" 1 "must not promote"
run "red-store-writes-noncanonical-json" "store writes non-canonical json" 1 "canonical bytes"
run "red-load-accepts-oversized-file" "store loads oversized file" 1 "store contract missing"

echo "--- RED: U1R18-R12-FIX1 durable receipt repairs (rc=1) ---"
run "red-default-success-persister" "success-default persister reintroduced" 1 "success-default persister"
run "red-persister-result-substitutes-receipt" "persister substitutes the receipt" 1 "persisted receipt identity"
run "red-write-failure-deletes-old-receipt" "write failure deletes old receipt" 1 "must not contain 'removeItem(at: receiptURL)"
run "red-load-path-data-contents" "load uses path-based Data(contentsOf:)" 1 "must not contain 'Data(contentsOf: receiptURL)"
run "red-load-nonregular-as-regular" "load treats non-regular as regular" 1 "prove regular-file before read"
run "red-load-fifo-before-type-check" "load reads FIFO before type check" 1 "store contract missing 'O_NONBLOCK"
run "red-load-without-nofollow" "load follows symlinks" 1 "store contract missing 'O_NOFOLLOW"
run "red-load-unbounded-read" "load reads unbounded" 1 "load read must be bounded"
run "red-load-read-failure-becomes-notfound" "read failure becomes notFound" 1 "must not become notFound"
run "red-load-stat-and-read-different-object" "load stats and reads different objects" 1 "must read via the opened FD"

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