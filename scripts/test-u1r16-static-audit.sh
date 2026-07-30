#!/bin/bash
# Test U1R16 static audit scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/u1r16_static_audit.py"
TEST_DIR="$(mktemp -d /tmp/macsteam-audit-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Helper: create a file in the fixture
mk_swift() {
    local dir="$1" subpath="$2" content="$3"
    mkdir -p "$dir/Sources/MacSteam/Views"
    echo "$content" > "$dir/Sources/MacSteam/Views/$subpath"
}

# Test 1: clean fixture
CLEAN="$TEST_DIR/clean"
mk_swift "$CLEAN" "TestView.swift" 'import SwiftUI'
mk_swift "$CLEAN" "StateView.swift" 'let x = coordinator.state'
python3 "$SCANNER" --root "$CLEAN/Sources/MacSteam/Views" >/dev/null 2>&1 && pass "clean returns 0" || fail "clean should return 0"

# Test 2: assignment detected
ASSN1="$TEST_DIR/assn1"
mk_swift "$ASSN1" "TestView.swift" 'coordinator.state = .steamReady'
python3 "$SCANNER" --root "$ASSN1/Sources/MacSteam/Views" >/dev/null 2>&1 && fail "assignment should be 1" || pass "assignment detected"

# Test 3: multi-space assignment
ASSN2="$TEST_DIR/assn2"
mk_swift "$ASSN2" "TestView.swift" 'coordinator.state     = .steamReady'
python3 "$SCANNER" --root "$ASSN2/Sources/MacSteam/Views" >/dev/null 2>&1 && fail "multi-space assign should be 1" || pass "multi-space detected"

# Test 4: equality comparison
EQ="$TEST_DIR/eq"
mk_swift "$EQ" "TestView.swift" 'if coordinator.state == .steamReady'
python3 "$SCANNER" --root "$EQ/Sources/MacSteam/Views" >/dev/null 2>&1 && pass "== returns 0" || fail "== should return 0"

# Test 5: inequality comparison
NEQ="$TEST_DIR/neq"
mk_swift "$NEQ" "TestView.swift" 'if coordinator.state != .steamReady'
python3 "$SCANNER" --root "$NEQ/Sources/MacSteam/Views" >/dev/null 2>&1 && pass "!= returns 0" || fail "!= should return 0"

# Test 6: missing root
python3 "$SCANNER" --root "$TEST_DIR/nonexistent" >/dev/null 2>&1 && fail "missing root should be exit 2" || pass "missing root exits 2"

# Test 7: run full audit script
AUDIT="$SCRIPT_DIR/u1r16-static-audit.sh"
cd "$SCRIPT_DIR/.."
bash "$AUDIT" >/dev/null 2>&1 && rc=$? || rc=$?
# Audit should find violations in existing code
[ "$rc" -eq 1 ] && pass "full audit exits 1 (expected violations)" || fail "full audit should exit 1"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Static audit test PASSED"
    exit 0
else
    echo "Static audit test FAILED — $FAILURES failure(s)"
    exit 1
fi
