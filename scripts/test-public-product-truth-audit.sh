#!/usr/bin/env bash
# test-public-product-truth-audit.sh — public product truth audit harness
#
# Exercises scripts/public-product-truth-audit.py against the fixture tree.
# Every GREEN fixture must pass (rc=0); every RED fixture must be rejected
# (rc=1) with the EXACT guard label. The harness self-checks the mapping the
# same way as the other U1R18 harnesses: a RED fixture without a mapping, a
# mapping without a fixture, an empty fixture, or two byte-identical fixtures
# is a FAIL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PY="scripts/public-product-truth-audit.py"
FIX="scripts/public-product-truth-fixtures"
GREEN="$FIX/green"
RED="$FIX/red"
BASE="$FIX/base"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()  { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# build <fixture_dir> -> copies base tree and overlays fixture README into TMP/tree
build_tree() {
    local src="$1"
    rm -rf "$TMP/tree"
    cp -R "$BASE" "$TMP/tree"
    if [ -f "$src/README.md" ]; then
        cp "$src/README.md" "$TMP/tree/README.md"
    fi
}

echo "=== Public product truth audit harness ==="
echo "--- toolchain prerequisites ---"
for f in "$PY" "Contracts/public-product-truth.schema.json" "$BASE/README.md" \
         "$BASE/docs/public-product-truth.json"; do
    if [ -f "$f" ]; then
        ok "prerequisite exists: $f"
    else
        bad "prerequisite missing: $f"
    fi
done

echo "--- GREEN: exact current truth (base) ---"
build_tree "$GREEN"
if python3 "$PY" audit --root "$TMP/tree" >/dev/null 2>&1; then
    ok "base/current truth passes"
else
    bad "base/current truth should pass"
fi

echo "--- GREEN: all variants pass ---"
for d in "$GREEN"/*/; do
    name=$(basename "$d")
    build_tree "$d"
    if python3 "$PY" audit --root "$TMP/tree" >/dev/null 2>&1; then
        ok "green passes: $name"
    else
        bad "green should pass but failed: $name"
    fi
done

echo "--- RED: exact guard assertions ---"
run_red() {
    local name="$1" exp_guard="$2"
    build_tree "$RED/$name"
    local out rc guard
    set +e
    out=$(python3 "$PY" audit --root "$TMP/tree" 2>&1)
    rc=$?
    set -e
    guard=$(python3 - "$out" <<'PY'
import json,sys
o=sys.argv[1]
try:
    d=json.loads(o)
    print(d.get("guard",""))
except Exception:
    print("")
PY
)
    if [ "$rc" -eq 1 ] && [ "$guard" = "$exp_guard" ]; then
        ok "red rejected $name -> $exp_guard"
    else
        bad "red $name (rc=$rc exp_rc=1 guard='$guard' exp='$exp_guard')"
    fi
}

run_red "r1-crossover-prerequisite" "public_truth_stale_crossover_prerequisite"
run_red "r2-crossover-canonical" "public_truth_stale_crossover_prerequisite"
run_red "r3-no-wine-support" "public_truth_stale_wine_claim"
run_red "r4-system-wine-default" "public_truth_runtime_invalid"
run_red "r5-managed-wine-available" "public_truth_runtime_invalid"
run_red "r6-installer-bundled" "public_truth_steam_invalid"
run_red "r7-installer-downloaded" "public_truth_steam_invalid"
run_red "r8-cloverpit-proven-playable" "public_truth_acceptance_overclaim"
run_red "r9-rendered-stable-claim" "public_truth_acceptance_overclaim"
run_red "r10-app-bundle-available" "public_truth_packaging_overclaim"
run_red "r11-codesign-notarize-complete" "public_truth_packaging_overclaim"
run_red "r12-release-download-available" "public_truth_release_overclaim"
run_red "r13-ready-merge-release-authorized" "public_truth_release_overclaim"
run_red "r14-name-reverted-macsteam" "public_truth_branding_invalid"
run_red "r15-r5-performed" "public_truth_r5_invalid"
run_red "r16-r5-claimed" "public_truth_r5_invalid"
run_red "r17-marker-missing" "public_truth_marker_missing"
run_red "r18-marker-duplicate" "public_truth_marker_duplicated"
run_red "r19-truth-only-in-comment" "public_truth_runtime_invalid"
run_red "r20-truth-in-unrelated-section" "public_truth_marker_missing"
run_red "r21-roadmap-minimal-complete" "public_truth_roadmap_invalid"
run_red "r22-roadmap-distribution-authorized" "public_truth_roadmap_invalid"

echo "--- harness mapping self-check ---"
EXPECTED_RED="r1-crossover-prerequisite r2-crossover-canonical r3-no-wine-support r4-system-wine-default r5-managed-wine-available r6-installer-bundled r7-installer-downloaded r8-cloverpit-proven-playable r9-rendered-stable-claim r10-app-bundle-available r11-codesign-notarize-complete r12-release-download-available r13-ready-merge-release-authorized r14-name-reverted-macsteam r15-r5-performed r16-r5-claimed r17-marker-missing r18-marker-duplicate r19-truth-only-in-comment r20-truth-in-unrelated-section r21-roadmap-minimal-complete r22-roadmap-distribution-authorized"

# every RED mapping must have a fixture
MISSING_FIX=0
for name in $EXPECTED_RED; do
    if [ ! -d "$RED/$name" ] || [ ! -f "$RED/$name/README.md" ]; then
        bad "RED mapping without fixture: $name"
        MISSING_FIX=1
    fi
done
[ "$MISSING_FIX" -eq 0 ] && ok "every RED mapping has a fixture"

# every RED fixture must have a mapping
ORPHAN=0
for d in "$RED"/*/; do
    name=$(basename "$d")
    case " $EXPECTED_RED " in
        *" $name "*) ;;
        *) bad "RED fixture without mapping: $name"; ORPHAN=1 ;;
    esac
done
[ "$ORPHAN" -eq 0 ] && ok "no orphan RED fixture"

# no empty fixtures
EMPTY=0
for f in "$GREEN"/*/README.md "$RED"/*/README.md "$BASE/README.md"; do
    if [ ! -s "$f" ]; then
        bad "empty fixture: $f"
        EMPTY=1
    fi
done
[ "$EMPTY" -eq 0 ] && ok "no empty fixtures"

# no byte-identical fixtures (compare only the green/ and red/ trees; base/ is
# a shared template whose content legitimately mirrors the repo README).
DUP=0
prev=""
for h in $(cd "$FIX" && find green red -type f | sort | while read -r f; do shasum -a 256 "$f"; done | cut -d' ' -f1); do
    if [ "$h" = "$prev" ] && [ -n "$h" ]; then
        bad "duplicate fixture content detected"
        DUP=1
    fi
    prev="$h"
done
[ "$DUP" -eq 0 ] && ok "no duplicate fixtures"

echo ""
echo "=== Product truth harness summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0