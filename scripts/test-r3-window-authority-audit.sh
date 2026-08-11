#!/usr/bin/env bash
set -euo pipefail

# R3 Semantic Mutation Harness — U1R18 Window Authority
#
# For each semantic mutation:
#   1. Apply a compile-valid mutation to production source
#   2. swift build → must exit 0 (compilation must succeed)
#   3. r3-window-authority-audit.py → must exit 1 (scanner rejects)
#   4. Targeted production-linked test → must fail
#   5. Restore clean source
#
# Scanner-only mutations (M3, M9, M10) skip step 4.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
TOTAL=0

FILES=(
    "Sources/MacSteam/Sessions/SessionWindowObserver.swift"
    "Sources/MacSteam/Sessions/HostProcessLineage.swift"
    "Sources/MacSteam/Sessions/GameSessionSupervisor.swift"
)

BACKUP_DIR=$(mktemp -d)

backup_all() {
    mkdir -p "$BACKUP_DIR"
    for f in "${FILES[@]}"; do
        cp "$f" "$BACKUP_DIR/$(echo "$f" | tr '/' '_')"
    done
}

restore_all() {
    for f in "${FILES[@]}"; do
        local bname=$(echo "$f" | tr '/' '_')
        if [ -f "$BACKUP_DIR/$bname" ]; then
            cp "$BACKUP_DIR/$bname" "$f"
        fi
    done
}
trap 'restore_all; rm -rf "$BACKUP_DIR"' EXIT

run_mutation() {
    local label="$1"
    local mutation_cmd="$2"
    local expected_test="$3"
    local expected_guard="$4"

    TOTAL=$((TOTAL + 1))
    echo "--- $label ---"

    eval "$mutation_cmd"

    # Step 1: swift build must succeed (compile-valid mutation)
    local build_rc=0
    swift build 2>&1 | tail -1 || build_rc=$?
    if [ "$build_rc" -ne 0 ]; then
        echo "[FAIL] $label: swift build failed (mutation must be compile-valid)"
        restore_all
        FAIL=$((FAIL + 1))
        return 1
    fi

    # Step 2: R3 scanner must reject (exit 1)
    local scanner_output
    local scanner_rc=0
    scanner_output=$(python3 "$SCRIPT_DIR/r3-window-authority-audit.py" 2>&1) || scanner_rc=$?
    if [ "$scanner_rc" -ne 1 ]; then
        echo "[FAIL] $label: scanner did not reject (exit $scanner_rc, expected 1)"
        restore_all
        FAIL=$((FAIL + 1))
        return 1
    fi

    # Verify exact guard label in scanner output
    if [ -n "$expected_guard" ]; then
        if ! echo "$scanner_output" | grep -q "$expected_guard"; then
            echo "[FAIL] $label: scanner rejected but missing expected guard label '$expected_guard'"
            echo "  Scanner output:"
            echo "$scanner_output" | sed 's/^/    /'
            restore_all
            FAIL=$((FAIL + 1))
            return 1
        fi
    fi

    # Step 3: Targeted test must fail (skip for scanner-only mutations)
    if [ "$expected_test" != "scanner_only" ] && [ -n "$expected_test" ]; then
        local test_rc=0
        swift test --filter "$expected_test" 2>&1 | tail -5 || test_rc=$?
        if [ "$test_rc" -eq 0 ]; then
            echo "[FAIL] $label: targeted test '$expected_test' did not fail"
            restore_all
            FAIL=$((FAIL + 1))
            return 1
        fi
    fi

    echo "[PASS] $label"
    PASS=$((PASS + 1))
    restore_all
}

run_decoy() {
    local label="$1"
    local mutation_cmd="$2"
    local expected_guard="$3"

    TOTAL=$((TOTAL + 1))
    echo "--- $label ---"

    eval "$mutation_cmd"

    local scanner_output
    local scanner_rc=0
    scanner_output=$(python3 "$SCRIPT_DIR/r3-window-authority-audit.py" 2>&1) || scanner_rc=$?
    if [ "$scanner_rc" -ne 1 ]; then
        echo "[FAIL] $label: scanner did not reject decoy (exit $scanner_rc)"
        echo "  Scanner output:"
        echo "$scanner_output" | sed 's/^/    /'
        restore_all
        FAIL=$((FAIL + 1))
        return 1
    fi

    if ! echo "$scanner_output" | grep -q "$expected_guard"; then
        echo "[FAIL] $label: scanner rejected but missing expected guard label '$expected_guard'"
        echo "  Scanner output:"
        echo "$scanner_output" | sed 's/^/    /'
        restore_all
        FAIL=$((FAIL + 1))
        return 1
    fi

    echo "[PASS] $label"
    PASS=$((PASS + 1))
    restore_all
}

echo "=== R3 Semantic Mutation Harness ==="
echo ""

# --- Clean baseline ---
echo "=== Clean Baseline ==="
backup_all

echo "  swift build..."
swift build 2>&1 | tail -1

echo "  r3 scanner..."
python3 "$SCRIPT_DIR/r3-window-authority-audit.py" | tail -1

echo "  R3 regression tests..."
swift test --filter R3WindowAuthorityRegressionTests 2>&1 | tail -1

echo ""

# --- Semantic mutations ---
echo "=== Semantic Mutations ==="
echo ""

# M1: Ownership-only positive — geometry filter replaces isValidCandidate
run_mutation \
    "M1_ownership_only_positive" \
    "sed -i '' 's/WindowMatcher.isValidCandidate(\$0, target: target)/WindowMatcher.isValidGeometry(\$0)/' Sources/MacSteam/Sessions/SessionWindowObserver.swift" \
    "R3WindowAuthorityRegressionTests/ownedGenericWineNeverVisible" \
    "observe_target_filter"

# M2: Target-only positive — remove ownership conjunction
run_mutation \
    "M2_target_only_positive" \
    "sed -i '' 's/targetCandidates.contains(where: { owned.contains(\$0.ownerPID) })/!targetCandidates.isEmpty/' Sources/MacSteam/Sessions/SessionWindowObserver.swift" \
    "R3WindowAuthorityRegressionTests/foreignSteamCandidateNeverVisible" \
    "owned_positive_same_candidate_conjunction"

# M3: Optional/default-nil ownershipSnapshot parameter
run_mutation \
    "M3_optional_default_nil_api" \
    "sed -i '' 's/ownershipSnapshot: @escaping WindowOwnershipSnapshot,/ownershipSnapshot: WindowOwnershipSnapshot? = nil,/' Sources/MacSteam/Sessions/SessionWindowObserver.swift && sed -i '' 's/self.ownershipSnapshot = ownershipSnapshot/self.ownershipSnapshot = ownershipSnapshot ?? { nil }/' Sources/MacSteam/Sessions/SessionWindowObserver.swift" \
    "scanner_only" \
    "ownership_parameter_non_optional"

# M4: Geometry-only nil-ownership fallback
run_mutation \
    "M4_geometry_only_fallback" \
    "sed -i '' 's/return .ownershipIncomplete/let hit = windows.contains { WindowMatcher.isValidGeometry(\$0) }; return hit ? .ownedPositive : .ownedMiss/' Sources/MacSteam/Sessions/SessionWindowObserver.swift" \
    "R3WindowAuthorityRegressionTests/ownershipNilWithNonTargetGeometryWindowStaysUnknown" \
    "exactly_one_positive_path"

# M5: Keyword-only nil-ownership fallback
run_mutation \
    "M5_keyword_only_fallback" \
    "sed -i '' 's/return .ownershipIncomplete/let hit = windows.contains { WindowMatcher.isValidCandidate(\$0, target: target) }; return hit ? .ownedPositive : .ownedMiss/' Sources/MacSteam/Sessions/SessionWindowObserver.swift" \
    "R3WindowAuthorityRegressionTests/ownershipNilWithTargetWindowStaysUnknown" \
    "exactly_one_positive_path"

# M6: Foreign candidate converted to positive
run_mutation \
    "M6_foreign_candidate_positive" \
    "sed -i '' 's/return .foreignCandidatesOnly/return .ownedPositive/' Sources/MacSteam/Sessions/SessionWindowObserver.swift" \
    "R3WindowAuthorityRegressionTests/foreignSteamCandidateNeverVisible" \
    "observe_foreign_candidates_only_case"

# M8: Cached-table replay bypasses coherent census
run_mutation \
    "M8_cached_capture_replay" \
    "sed -i '' 's/let result = census(ledger: &ledger)/let result = ProcessCensusResult(state: .proven, liveDescendants: 0, liveOrphans: 0, zombieCount: 0, exitedCount: 0, pidReuseCount: 0, totalLive: 0, error: nil)/' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "GameSessionSupervisorWindowTests/isRunningAcrossWindowStates" \
    "owned_process_ids_delegates_to_census"

# M9: Non-proven returns Set() instead of nil
run_mutation \
    "M9_nonproven_returns_set" \
    "sed -i '' 's/guard result.state == .proven else { return nil }/guard result.state == .proven else { return Set() }/' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "scanner_only" \
    "non_proven_ownership_must_return_nil"

# M10: Recovery PID fabrication — returns Set([0]) when no ledger
run_mutation \
    "M10_recovery_pid_fabrication" \
    "sed -i '' 's/guard var ledger = censusLedger else { return nil }/guard var ledger = censusLedger else { return Set([0]) }/' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "scanner_only" \
    "missing_ledger_must_return_nil"

# --- Adversarial decoy fixtures (scanner-only, no build needed) ---
echo ""
echo "=== Adversarial Decoy Fixtures ==="
echo ""

# Decoy 1: Correct conjunction only in a comment.
# Mutation: replace the actual conjunction with !targetCandidates.isEmpty,
#           then add a comment containing the correct conjunction.
# Scanner must strip the comment and reject.
run_decoy \
    "decoy_correct_conjunction_in_comment" \
    'python3 << "DECISION"
f = "Sources/MacSteam/Sessions/SessionWindowObserver.swift"
c = open(f).read()
c = c.replace(
    "if targetCandidates.contains(where: { owned.contains($0.ownerPID) })",
    "if !targetCandidates.isEmpty // decoy: targetCandidates.contains(where: { owned.contains($0.ownerPID) })"
)
open(f, "w").write(c)
DECISION' \
    "owned_positive_same_candidate_conjunction"

# Decoy 2: Correct conjunction only in a string literal.
# Mutation: replace the actual conjunction with !targetCandidates.isEmpty,
#           then add a string literal containing the correct conjunction.
run_decoy \
    "decoy_correct_conjunction_in_string" \
    'python3 << "DECISION"
f = "Sources/MacSteam/Sessions/SessionWindowObserver.swift"
c = open(f).read()
c = c.replace(
    "if targetCandidates.contains(where: { owned.contains($0.ownerPID) })",
    "if !targetCandidates.isEmpty // \"decoy: targetCandidates.contains(where: { owned.contains($0.ownerPID) })\""
)
open(f, "w").write(c)
DECISION' \
    "owned_positive_same_candidate_conjunction"

# Decoy 3: Correct nil-guard only in #if false block.
# Mutation: replace return nil with return Set([0]), add the correct guard
#           in an #if false block. Scanner must strip #if false and reject.
run_decoy \
    "decoy_correct_nil_guard_in_if_false" \
    'python3 << "DECISION"
f = "Sources/MacSteam/Sessions/GameSessionSupervisor.swift"
c = open(f).read()
c = c.replace(
    "guard var ledger = censusLedger else { return nil }",
    "guard var ledger = censusLedger else { return Set([0]) } // decoy: #if false guard var ledger = censusLedger else { return nil } #endif"
)
open(f, "w").write(c)
DECISION' \
    "missing_ledger_must_return_nil"

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL  Total: $TOTAL"
restore_all
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL mutation fixtures did not behave as expected."
    exit 1
fi
echo "All R3 semantic mutation fixtures passed."
