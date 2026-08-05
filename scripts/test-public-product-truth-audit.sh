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

# tree_rp: resolved path of the current copied tree (for symlink-escape and
# outside-tree resolution checks). Rebuilt on each build_tree invocation.
tree_rp=""

# validate_delete_paths <file> -> fail-closed validation of delete-paths.txt.
# Rejects (echoes ONE diagnostic line, returns 1): absolute paths, "..",
# backslash, empty/whitespace-only entries, duplicate entries, TAB, CR, NUL,
# DEL, any other ASCII control character, invalid UTF-8, missing paths,
# directory deletions, symlinks, and any path resolving outside the copied
# base tree. LF is the only permitted line delimiter. Nothing is silently
# skipped/trimmed/accepted.
validate_delete_paths() {
    local file="$1" line n=0 seen="$TMP/.del-seen.$$"
    : > "$seen"
    if LC_ALL=C grep -q $'\r' "$file"; then
        echo "delete-paths.txt contains CR (LF-only line delimiter required)"
        rm -f "$seen"; return 1
    fi
    if LC_ALL=C grep -q $'\t' "$file"; then
        echo "delete-paths.txt contains a TAB"
        rm -f "$seen"; return 1
    fi
    if LC_ALL=C tr -d '\n\t\r' < "$file" | LC_ALL=C grep -aq '[[:cntrl:]]'; then
        echo "delete-paths.txt contains ASCII control characters (NUL/DEL/etc.)"
        rm -f "$seen"; return 1
    fi
    if ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
        echo "delete-paths.txt is not valid UTF-8"
        rm -f "$seen"; return 1
    fi
    while IFS= read -r line; do
        n=$((n + 1))
        if [ -z "$line" ]; then
            echo "delete-paths.txt line $n: empty entry"
            rm -f "$seen"; return 1
        fi
        if [ -z "$(printf '%s' "$line" | LC_ALL=C tr -d '[:space:]')" ]; then
            echo "delete-paths.txt line $n: whitespace-only entry"
            rm -f "$seen"; return 1
        fi
        case "$line" in
            /*) echo "delete-paths.txt line $n: absolute path: $line"
                rm -f "$seen"; return 1 ;;
            *..*) echo "delete-paths.txt line $n: path with '..': $line"
                rm -f "$seen"; return 1 ;;
            *\\*) echo "delete-paths.txt line $n: path with backslash: $line"
                rm -f "$seen"; return 1 ;;
        esac
        if LC_ALL=C grep -qxF "$line" "$seen"; then
            echo "delete-paths.txt line $n: duplicate entry: $line"
            rm -f "$seen"; return 1
        fi
        printf '%s\n' "$line" >> "$seen"
        local target="$TMP/tree/$line"
        if [ ! -e "$target" ]; then
            echo "delete-paths.txt line $n: path missing in base tree: $line"
            rm -f "$seen"; return 1
        fi
        if [ -d "$target" ]; then
            echo "delete-paths.txt line $n: directory deletion: $line"
            rm -f "$seen"; return 1
        fi
        if [ -L "$target" ]; then
            echo "delete-paths.txt line $n: symlink not permitted: $line"
            rm -f "$seen"; return 1
        fi
        local rp
        rp="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")" || rp=""
        if [ -z "$rp" ]; then
            echo "delete-paths.txt line $n: cannot resolve path: $line"
            rm -f "$seen"; return 1
        fi
        case "$rp" in
            "$tree_rp"/*) ;;
            *) echo "delete-paths.txt line $n: resolves outside repo tree: $line"
               rm -f "$seen"; return 1 ;;
        esac
    done < "$file"
    rm -f "$seen"
    return 0
}

# build <fixture_dir> -> copies base tree, applies delete-paths.txt, then
# recursively overlays every other file in the fixture over the tree.
build_tree() {
    local src="$1"
    rm -rf "$TMP/tree"
    cp -R "$BASE" "$TMP/tree"
    tree_rp="$(cd "$TMP/tree" && pwd -P)"

    if [ -f "$src/delete-paths.txt" ]; then
        local err
        if ! err="$(validate_delete_paths "$src/delete-paths.txt")"; then
            bad "invalid delete-paths.txt: $err"
            return 1
        fi
        while IFS= read -r rel; do
            rm -f "$TMP/tree/$rel"
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

# --- §11 matrix A: semantic independence (15) ---
for f in \
    "a1-semantic-branding-display-name" \
    "a2-semantic-branding-internal-module" \
    "a3-semantic-platform-os" \
    "a4-semantic-platform-min-version" \
    "a5-semantic-platform-arch" \
    "a6-semantic-runtime-wine-discoverable" \
    "a7-semantic-runtime-wine-by-default" \
    "a8-semantic-runtime-managed-available" \
    "a9-semantic-runtime-crossover-canonical" \
    "a10-semantic-runtime-crossover-required" \
    "a11-semantic-runtime-crossover-default" \
    "a12-semantic-steam-credentials" \
    "a13-semantic-packaging-app-bundle" \
    "a14-semantic-packaging-codesigned" \
    "a15-semantic-packaging-notarized"; do
    run_red "$f" "public_truth_semantic_invalid"
done

# --- §11 matrix B: schema self-contract (7) ---
for f in \
    "b1-schema-wrong-draft-id" \
    "b2-schema-root-type-removed" \
    "b3-schema-section-type-removed" \
    "b4-schema-scalar-type-removed" \
    "b5-schema-scalar-type-changed" \
    "b6-schema-additional-properties-widened" \
    "b7-schema-required-dropped"; do
    run_red "$f" "public_truth_schema_invalid"
done

# --- §11 matrix C: README owner-section (18) ---
run_red "c1-readme-current-status-fact-removed" "public_truth_docs_drift"
run_red "c2-readme-runtime-fact-moved" "public_truth_runtime_invalid"
run_red "c3-readme-how-it-works-fence-only" "public_truth_docs_drift"
run_red "c4-readme-distribution-fact-removed" "public_truth_docs_drift"
run_red "c5-readme-safety-comment-only" "public_truth_docs_drift"
run_red "c6-readme-limitations-fact-removed" "public_truth_docs_drift"
run_red "c7-readme-setup-flow-comment-only" "public_truth_steam_invalid"
run_red "c8-readme-crossover-disabled-default-removed" "public_truth_runtime_invalid"
run_red "c9-readme-crossover-optin-removed" "public_truth_runtime_invalid"
run_red "c10-readme-crossover-lowest-priority-removed" "public_truth_runtime_invalid"
run_red "c11-readme-crossover-never-prerequisite-removed" "public_truth_runtime_invalid"
run_red "c12-readme-minimal-lane-mutated" "public_truth_roadmap_invalid"
run_red "c13-readme-general-lane-mutated" "public_truth_roadmap_invalid"
run_red "c14-readme-roadmap-lane-complete-claim" "public_truth_roadmap_invalid"
run_red "c15-readme-roadmap-lane-authorized-claim" "public_truth_roadmap_invalid"
run_red "c16-readme-fake-fenced-l2-heading" "public_truth_docs_drift"
run_red "c17-readme-duplicate-l2-heading" "public_truth_docs_drift"
run_red "c18-readme-r5-moved" "public_truth_r5_invalid"

# --- §11 matrix D: canonical docs (10) ---
run_red "d1-arch-crossover-disabled-default-removed" "public_truth_docs_drift"
run_red "d2-arch-crossover-optin-removed" "public_truth_docs_drift"
run_red "d3-arch-crossover-lowest-priority-removed" "public_truth_docs_drift"
run_red "d4-arch-crossover-never-prerequisite-removed" "public_truth_docs_drift"
run_red "d5-arch-overview-fence-only" "public_truth_docs_drift"
run_red "d6-arch-overview-unrelated-only" "public_truth_docs_drift"
run_red "d7-steam-credential-removed" "public_truth_docs_drift"
run_red "d8-steam-credential-overview-only" "public_truth_docs_drift"
run_red "d9-steam-credential-comment-only" "public_truth_docs_drift"
run_red "d10-steam-credential-fence-only" "public_truth_docs_drift"

# --- §4 residual closures (FIX2, 16) ---
run_red "e1-runtime-generic-bound-imported-wine" "public_truth_runtime_invalid"
run_red "e2-runtime-generic-bound-system-wine" "public_truth_runtime_invalid"
run_red "e3-current-status-not-yet-available-other-feature" "public_truth_docs_drift"
run_red "e4-how-it-works-generic-runtime-detection" "public_truth_docs_drift"
run_red "e5-limitations-metadata-removed" "public_truth_docs_drift"
run_red "e6-limitations-save-removed" "public_truth_docs_drift"
run_red "e7-limitations-cloud-removed" "public_truth_docs_drift"
run_red "e8-roadmap-minimal-authorized" "public_truth_roadmap_invalid"
run_red "e9-roadmap-minimal-complete" "public_truth_roadmap_invalid"
run_red "e10-roadmap-general-authorized" "public_truth_roadmap_invalid"
run_red "e11-roadmap-general-complete" "public_truth_roadmap_invalid"
run_red "e12-roadmap-positive-masked-by-negative" "public_truth_roadmap_invalid"
run_red "e13-marker-before-h1" "public_truth_marker_missing"
run_red "e14-marker-fake-fenced-h1" "public_truth_marker_missing"
run_red "e15-marker-missing-visible-h1" "public_truth_branding_invalid"
run_red "e16-arch-overview-duplicate-owner" "public_truth_docs_drift"

# --- §4 exact owner uniqueness + §5 product H1 authority (FIX3, 13) ---
run_red "f1-owner-first-complete-second-incomplete" "public_truth_docs_drift"
run_red "f2-owner-two-complete-duplicates" "public_truth_docs_drift"
run_red "f3-owner-different-names-both-match" "public_truth_docs_drift"
run_red "f4-owner-fenced-comment-hidden-copy" "public_truth_docs_drift"
run_red "f5-owner-missing-section" "public_truth_docs_drift"
run_red "f6-h1-other-product-prose" "public_truth_branding_invalid"
run_red "f7-h1-other-then-macsteam" "public_truth_branding_invalid"
run_red "f8-h1-two-macsteam" "public_truth_branding_invalid"
run_red "f9-h1-macsteam-plus-other" "public_truth_branding_invalid"
run_red "f10-h1-fenced-only" "public_truth_branding_invalid"
run_red "f11-h1-comment-only" "public_truth_branding_invalid"
run_red "f12-h1-marker-before" "public_truth_marker_missing"
run_red "f13-h1-no-visible-h1" "public_truth_branding_invalid"

echo "--- harness mapping self-check ---"
EXPECTED_RED="r1-crossover-prerequisite r2-crossover-canonical r3-no-wine-support r4-system-wine-default r5-managed-wine-available r6-installer-bundled r7-installer-downloaded r8-cloverpit-proven-playable r9-rendered-stable-claim r10-app-bundle-available r11-codesign-notarize-complete r12-release-download-available r13-ready-merge-release-authorized r14-name-reverted-macsteam r15-r5-performed r16-r5-claimed r17-marker-missing r18-marker-duplicate r19-truth-only-in-comment r20-truth-in-unrelated-section r21-roadmap-minimal-complete r22-roadmap-distribution-authorized r23-schema-weakened-app-id r24-manifest-app-id-wrong r25-schema-missing r26-schema-invalid-json r27-authority-missing r28-authority-invalid-json r29-readme-missing r30-readme-current-status-missing r31-readme-runtime-section-duplicate r32-readme-runtime-truth-wrong-section-only r33-readme-roadmap-general-lane-missing r34-readme-roadmap-positive-authorized r35-canonical-doc-missing r36-architecture-positive-binding-removed r37-runtime-contract-positive-binding-removed r38-steam-boundary-positive-binding-removed r39-distribution-boundaries-positive-binding-removed r40-schema-weakened-plus-semantic-false r41-cloverpit-app-id-doc-wrong a1-semantic-branding-display-name a2-semantic-branding-internal-module a3-semantic-platform-os a4-semantic-platform-min-version a5-semantic-platform-arch a6-semantic-runtime-wine-discoverable a7-semantic-runtime-wine-by-default a8-semantic-runtime-managed-available a9-semantic-runtime-crossover-canonical a10-semantic-runtime-crossover-required a11-semantic-runtime-crossover-default a12-semantic-steam-credentials a13-semantic-packaging-app-bundle a14-semantic-packaging-codesigned a15-semantic-packaging-notarized b1-schema-wrong-draft-id b2-schema-root-type-removed b3-schema-section-type-removed b4-schema-scalar-type-removed b5-schema-scalar-type-changed b6-schema-additional-properties-widened b7-schema-required-dropped c1-readme-current-status-fact-removed c2-readme-runtime-fact-moved c3-readme-how-it-works-fence-only c4-readme-distribution-fact-removed c5-readme-safety-comment-only c6-readme-limitations-fact-removed c7-readme-setup-flow-comment-only c8-readme-crossover-disabled-default-removed c9-readme-crossover-optin-removed c10-readme-crossover-lowest-priority-removed c11-readme-crossover-never-prerequisite-removed c12-readme-minimal-lane-mutated c13-readme-general-lane-mutated c14-readme-roadmap-lane-complete-claim c15-readme-roadmap-lane-authorized-claim c16-readme-fake-fenced-l2-heading c17-readme-duplicate-l2-heading c18-readme-r5-moved d1-arch-crossover-disabled-default-removed d2-arch-crossover-optin-removed d3-arch-crossover-lowest-priority-removed d4-arch-crossover-never-prerequisite-removed d5-arch-overview-fence-only d6-arch-overview-unrelated-only d7-steam-credential-removed d8-steam-credential-overview-only d9-steam-credential-comment-only d10-steam-credential-fence-only e1-runtime-generic-bound-imported-wine e2-runtime-generic-bound-system-wine e3-current-status-not-yet-available-other-feature e4-how-it-works-generic-runtime-detection e5-limitations-metadata-removed e6-limitations-save-removed e7-limitations-cloud-removed e8-roadmap-minimal-authorized e9-roadmap-minimal-complete e10-roadmap-general-authorized e11-roadmap-general-complete e12-roadmap-positive-masked-by-negative e13-marker-before-h1 e14-marker-fake-fenced-h1 e15-marker-missing-visible-h1 e16-arch-overview-duplicate-owner f1-owner-first-complete-second-incomplete f2-owner-two-complete-duplicates f3-owner-different-names-both-match f4-owner-fenced-comment-hidden-copy f5-owner-missing-section f6-h1-other-product-prose f7-h1-other-then-macsteam f8-h1-two-macsteam f9-h1-macsteam-plus-other f10-h1-fenced-only f11-h1-comment-only f12-h1-marker-before f13-h1-no-visible-h1"

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

# no content-identical fixtures: GLOBAL digest dedup across ALL fixtures.
# Canonical payload digest = (sorted relative paths + per-file digest +
# delete-paths.txt content). All fixtures are collected as digest<TAB>identity
# and grouped/sorted by digest; any digest shared by >= 2 fixtures is a FAIL
# regardless of tree position (non-adjacent duplicates are still detected).
# Bash 3 compatible (no associative arrays), locale-stable (LC_ALL=C sort).
fixture_digest() {
    local d="$1"
    {
        while IFS= read -r -d '' f; do
            printf '%s\n' "${f#$d/}"
            shasum -a 256 "$f" | cut -d' ' -f1
        done < <(find "$d" -type f -print0 | sort -z)
        if [ -f "$d/delete-paths.txt" ]; then
            printf 'DEL\n'
            shasum -a 256 "$d/delete-paths.txt" | cut -d' ' -f1
        fi
    } | shasum -a 256 | cut -d' ' -f1
}

# global_dedup <dir...> -> prints diagnostics for every duplicate group and
# returns 1 if any digest is shared by >= 2 fixtures (0 otherwise).
global_dedup() {
    local digests="$TMP/.dedup-digests.$$"
    : > "$digests"
    local d name h
    for d in "$@"; do
        name=$(basename "$d")
        h=$(fixture_digest "$d")
        printf '%s\t%s\n' "$h" "$name" >> "$digests"
    done
    local prev="" line h2 name2 dup=0
    while IFS= read -r line; do
        h2="${line%%$'\t'*}"
        name2="${line#*$'\t'}"
        if [ -n "$prev" ] && [ "$h2" = "$prev" ]; then
            echo "duplicate fixture payload: $name2 (same digest as $prev_name)"
            dup=1
        fi
        prev="$h2"
        prev_name="$name2"
    done < <(LC_ALL=C sort -t$'\t' -k1,1 "$digests")
    rm -f "$digests"
    return "$dup"
}

DUP=0
if global_dedup "$GREEN"/*/ "$RED"/*/; then
    ok "no duplicate fixtures (global digest dedup)"
else
    DUP=1
fi

echo "--- §9 global-dedup self-test (non-adjacent duplicate detection) ---"
SELF="$TMP/.dedup-self"
rm -rf "$SELF"; mkdir -p "$SELF/A" "$SELF/B" "$SELF/C"
printf 'payload-X\n' > "$SELF/A/file.txt"
printf 'payload-Y\n' > "$SELF/B/file.txt"
printf 'payload-X\n' > "$SELF/C/file.txt"
if global_dedup "$SELF/A" "$SELF/B" "$SELF/C" > "$SELF/out" 2>&1; then
    bad "global dedup self-test: non-adjacent A/C duplicate NOT detected"
else
    if grep -q "duplicate fixture payload: C (same digest as A)" "$SELF/out"; then
        ok "global dedup self-test: non-adjacent A/C detected"
    else
        bad "global dedup self-test wrong diagnostics: $(tr '\n' ' ' < "$SELF/out")"
    fi
fi
rm -rf "$SELF"
# self-test fixtures live only under $TMP, never in the production tree

echo "--- §10 delete-paths fail-closed self-test ---"
# Direct validation self-test (does not go through build_tree, which would
# report a global FAIL for a legitimately-invalid control file). Each case
# proves validate_delete_paths rejects the payload.
del_rejects() {
    local label="$1" content="$2"
    local d="$TMP/.del-self"
    rm -rf "$d"; mkdir -p "$d"; cp -R "$BASE" "$d/tree"
    tree_rp="$(cd "$d/tree" && pwd -P)"
    printf '%b' "$content" > "$d/delete-paths.txt"
    if validate_delete_paths "$d/delete-paths.txt" >/dev/null 2>&1; then
        bad "delete-paths self-test $label: NOT rejected"
    else
        ok "delete-paths self-test $label: rejected"
    fi
    rm -rf "$d"
}
del_rejects "TAB" 'README.md\t\n'
del_rejects "CR" 'README.md\r\n'
del_rejects "traversal" '../README.md\n'
del_rejects "absolute" '/etc/passwd\n'
del_rejects "backslash" 'README.md\\x\n'
del_rejects "missing target" 'docs/no-such-file.md\n'
del_rejects "duplicate" 'README.md\nREADME.md\n'
del_rejects "whitespace-only" '   \n'
del_rejects "NUL" 'README.md\x00\n'
del_rejects "DEL" 'README.md\x7f\n'
del_rejects "invalid UTF-8" '\xff\xfe\n'

echo ""
echo "=== Product truth harness summary: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0