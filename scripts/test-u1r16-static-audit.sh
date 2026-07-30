#!/bin/bash
# Test U1R16 static audit scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/u1r16-static-audit.sh"
SCANNER="$SCRIPT_DIR/u1r16_static_audit.py"
TEST_DIR="$(mktemp -d /tmp/macsteam-audit-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

export GIT_PAGER=cat GIT_TERMINAL_PROMPT=0

make_git() {
    local dir="$1"
    mkdir -p "$dir/Sources/MacSteam/Views" "$dir/scripts"
    ln -sf "$SCANNER" "$dir/scripts/u1r16_static_audit.py" 2>/dev/null || true
}

# Test 1: clean fixture
make_git "$TEST_DIR/clean"
echo 'import SwiftUI' > "$TEST_DIR/clean/Sources/MacSteam/Views/TestView.swift'
echo 'let x = coordinator.state' > "$TEST_DIR/clean/Sources/MacSteam/Views/StateView.swift'
cd "$TEST_DIR/clean"
git init -q && git add -A 2>/dev/null
python3 scripts/u1r16_static_audit.py >/dev/null 2>&1 && pass "clean scanner returns 0" || fail "clean scanner should return 0"

# Test 2: assignment detected (single =)
make_git "$TEST_DIR/assn1"
echo 'coordinator.state = .steamReady' > "$TEST_DIR/assn1/Sources/MacSteam/Views/TestView.swift'
cd "$TEST_DIR/assn1"
git init -q && git add -A 2>/dev/null
python3 scripts/u1r16_static_audit.py >/dev/null 2>&1 && fail "assignment = should be detected" || pass "assignment = detected"

# Test 3: multi-space assignment detected
make_git "$TEST_DIR/assn2"
echo 'coordinator.state     = .steamReady' > "$TEST_DIR/assn2/Sources/MacSteam/Views/TestView.swift'
cd "$TEST_DIR/assn2"
git init -q && git add -A 2>/dev/null
python3 scripts/u1r16_static_audit.py >/dev/null 2>&1 && fail "multi-space assignment should be detected" || pass "multi-space assignment detected"

# Test 4: equality comparison excluded
make_git "$TEST_DIR/eq"
echo 'if coordinator.state == .steamReady' > "$TEST_DIR/eq/Sources/MacSteam/Views/TestView.swift"
cd "$TEST_DIR/eq"
git init -q && git add -A 2>/dev/null
python3 scripts/u1r16_static_audit.py >/dev/null 2>&1 && pass "== comparison excluded" || fail "== comparison should be excluded"

# Test 5: inequality comparison excluded
make_git "$TEST_DIR/neq"
echo 'if coordinator.state != .steamReady' > "$TEST_DIR/neq/Sources/MacSteam/Views/TestView.swift"
cd "$TEST_DIR/neq"
git init -q && git add -A 2>/dev/null
python3 scripts/u1r16_static_audit.py >/dev/null 2>&1 && pass "!= comparison excluded" || fail "!= comparison should be excluded"

# Test 6: missing path returns error
python3 scripts/u1r16_static_audit.py --nonexistent 2>/dev/null && fail "missing path should return error" || pass "missing path returns error"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Static audit test PASSED"
    exit 0
else
    echo "Static audit test FAILED — $FAILURES failure(s)"
    exit 1
fi
