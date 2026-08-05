#!/usr/bin/env bash
# test-public-product-truth-audit.sh — public product truth audit harness
#
# Exercises scripts/public-product-truth-audit.py against the fixture tree.
# Every GREEN fixture must pass (rc=0); every RED fixture must be rejected
# (rc=1) with the EXACT guard label. The harness self-checks the mapping the
# same way as the other U1R18 harnesses: a RED fixture without a mapping, a
# mapping without a fixture, an empty fixture, or two content-identical
# fixtures is a FAIL.
#
# Fixture overlay model:
#   - $BASE/** is the shared template (copied verbatim to the tree).
#   - A fixture dir's files are copied recursively over the base (any file,
#     including nested Contracts/ or docs/ overlays), so a fixture can mutate
#     the schema, the authority manifest, README.md, or any canonical doc.
#   - An optional delete-paths.txt declares repo-relative paths to DELETE
#     from the tree (e.g. to simulate a missing schema / authority / doc).
#     Delete paths must be repo-relative, contain no ".." or leading slash,
#     and name a file that exists in the copied tree.
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

# delete_path <rel> -> ensure rel is a safe repo-relative path, else die
delete_path() {
    local rel="$1"
    case "$rel" in
        /*) bad "unsafe absolute delete path: $rel"; return 1 ;;
        *..*) bad "unsafe delete path with '..': $rel"; return 1 ;;
        *\\*) bad "unsafe delete path with backslash: $rel"; return 1 ;;
        *$'\r') return 0 ;;
        '') return 0 ;;
    esac
    local target="$TMP/tree/$rel"
    if [ ! -e "$target" ]; then
        bad "delete path names a missing file: $rel"
        return 1
    fi
    rm -f "$target"
    return 0
}

# build <fixture_dir> -> copies base tree, applies delete-paths.txt, then
# recursively overlays every other file in the fixture over the tree.
build_tree() {
    local src="$1"
    rm -rf "$TMP/tree"
    cp -R "$BASE" "$TMP/tree"

    if [ -f "$src/delete-paths.txt" ]; then
        while IFS= read -r rel; do
            delete_path "$rel" || return 1
        done < "$src/delete-paths.txt"
    fi

    # recursive overlay: copy every non-control file, preserving structure
    local f
    while IFS= read -r -d '' f; do
        local rel="${f#$src/}"
        case "$rel" in
            delete-paths.txt) continue ;;
        esac
        local dst="$TMP/tree/$rel"
        mkdir -p "$(dirname "$dst")"
        cp "$f" "$dst"
    done < <(find "$src" -type f -print0)
}

echo "=== Public product truth audit harness ==="
echo "--- toolchain prerequisites ---"
for f in "$PY" "Contracts/public-product-truth.schema.json" "$BASE/README.md" \
         "$BASE/docs/public-product-truth.json" "$BASE/docs/ARCHITECTURE.md" \
         "$BASE/docs/RUNTIME_CONTRACT.md" "$BASE/docs/STEAM_BOUNDARY.md"; do
    if [ -f "$f" ]; then
        ok "prerequisite exists: $f"
    else
        bad "prerequisite missing: $f"
    fi
done

echo "--- GREEN: exact current truth (base) ---"
build_tree "$GREEN" || { bad "build_tree failed for base green"; }
if python3 "$PY" audit --root "$TMP/tree" >/dev/null 2>&1; then
    ok "base/current truth passes"
else
    bad "base/current truth should pass"
fi

echo "--- GREEN: all variants pass ---"
for d in "$GREEN"/*/; do
    name=$(basename "$d")
    if build_tree "$d" 2>/dev/null; then
        if python3 "$PY" audit --root "$TMP/tree" >/dev/null 2>&1; then
            ok "green passes: $name"
        else
            bad "green should pass but failed: $name"
        fi
    else
        bad "build_tree failed: $name"
    fi
done

echo "--- RED: exact guard assertions ---"
run_red() {
    local name="$1" exp_guard="$2"
    local exp_rc="${3:-1}" out rc guard
    if ! build_tree "$RED/$name" 2>/dev/null; then
        bad "red $name build_tree failed"
        return
    fi
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
    if [ "$rc" -eq "$exp_rc" ] && [ "$guard" = "$exp_guard" ]; then
        ok "red rejected $name -> $exp_guard"
    else
        bad "red $name (rc=$rc exp_rc=$exp_rc guard='$guard' exp='$exp_guard')"
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
run_red "r23-schema-weakened-app-id" "public_truth_schema_invalid"
run_red "r24-manifest-app-id-wrong" "public_truth_schema_invalid"
run_red "r25-schema-missing" "public_truth_schema_io_error" 2
run_red "r26-schema-invalid-json" "public_truth_schema_parse_error" 2
run_red "r27-authority-missing" "public_truth_authority_io_error" 2
run_red "r28-authority-invalid-json" "public_truth_authority_parse_error" 2
run_red "r29-readme-missing" "public_truth_readme_io_error" 2
run_red "r30-readme-current-status-missing" "public_truth_docs_drift"
run_red "r31-readme-runtime-section-duplicate" "public_truth_docs_drift"
run_red "r32-readme-runtime-truth-wrong-section-only" "public_truth_runtime_invalid"
run_red "r33-readme-roadmap-general-lane-missing" "public_truth_roadmap_invalid"
run_red "r34-readme-roadmap-positive-authorized" "public_truth_roadmap_invalid"
run_red "r35-canonical-doc-missing" "public_truth_docs_drift"
run_red "r36-architecture-positive-binding-removed" "public_truth_docs_drift"
run_red "r37-runtime-contract-positive-binding-removed" "public_truth_docs_drift"
run_red "r38-steam-boundary-positive-binding-removed" "public_truth_docs_drift"
run_red "r39-distribution-boundaries-positive-binding-removed" "public_truth_docs_drift"
run_red "r40-schema-weakened-plus-semantic-false" "public_truth_semantic_invalid"
run_red "r41-cloverpit-app-id-doc-wrong" "public_truth_docs_drift"

echo "--- harness mapping self-check ---"
EXPECTED_RED="r1-crossover-prerequisite r2-crossover-canonical r3-no-wine-support r4-system-wine-default r5-managed-wine-available r6-installer-bundled r7-installer-downloaded r8-cloverpit-proven-playable r9-rendered-stable-claim r10-app-bundle-available r11-codesign-notarize-complete r12-release-download-available r13-ready-merge-release-authorized r14-name-reverted-macsteam r15-r5-performed r16-r5-claimed r17-marker-missing r18-marker-duplicate r19-truth-only-in-comment r20-truth-in-unrelated-section r21-roadmap-minimal-complete r22-roadmap-distribution-authorized r23-schema-weakened-app-id r24-manifest-app-id-wrong r25-schema-missing r26-schema-invalid-json r27-authority-missing r28-authority-invalid-json r29-readme-missing r30-readme-current-status-missing r31-readme-runtime-section-duplicate r32-readme-runtime-truth-wrong-section-only r33-readme-roadmap-general-lane-missing r34-readme-roadmap-positive-authorized r35-canonical-doc-missing r36-architecture-positive-binding-removed r37-runtime-contract-positive-binding-removed r38-steam-boundary-positive-binding-removed r39-distribution-boundaries-positive-binding-removed r40-schema-weakened-plus-semantic-false r41-cloverpit-app-id-doc-wrong"

# every RED mapping must have a fixture dir with at least one overlay/control file
MISSING_FIX=0
for name in $EXPECTED_RED; do
    if [ ! -d "$RED/$name" ]; then
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

# no empty fixtures (control files and overlay files must be non-empty;
# base/ is a shared template and is exempt)
EMPTY=0
for f in "$GREEN"/* "${RED}"/*/delete-paths.txt; do
    [ -e "$f" ] || continue
    if [ -f "$f" ] && [ ! -s "$f" ]; then
        bad "empty fixture entry: $f"
        EMPTY=1
    fi
done
while IFS= read -r -d '' f; do
    if [ ! -s "$f" ]; then
        bad "empty overlay file: $f"
        EMPTY=1
    fi
done < <(find "$GREEN" "$RED" -type f ! -name delete-paths.txt -print0)
[ "$EMPTY" -eq 0 ] && ok "no empty fixtures"

# no content-identical fixtures: for each fixture dir, build a global digest
# over (sorted relative paths + bytes + delete-paths content). Two fixtures
# with the same digest are duplicates.
DUP=0
prev_fixture=""
prev_hash=""
while IFS= read -r -d '' d; do
    name=$(basename "$d")
    # sorted, path-qualified content lines -> hash
    content="$(
        while IFS= read -r -d '' f; do
            rel="${f#$d/}"
            printf '%s\n' "$rel"
            shasum -a 256 "$f" | cut -d' ' -f1
        done < <(find "$d" -type f -print0 | sort -z)
        if [ -f "$d/delete-paths.txt" ]; then
            printf 'DEL\n'
            shasum -a 256 "$d/delete-paths.txt" | cut -d' ' -f1
        fi
    )"
    h=$(printf '%s' "$content" | shasum -a 256 | cut -d' ' -f1)
    if [ -n "$prev_hash" ] && [ "$h" = "$prev_hash" ]; then
        bad "duplicate fixture content: $name matches $prev_fixture"
        DUP=1
    fi
    prev_fixture="$name"
    prev_hash="$h"
done < <(find "$GREEN" "$RED" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
[ "$DUP" -eq 0 ] && ok "no duplicate fixtures"

echo ""
echo "=== Product truth harness summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0