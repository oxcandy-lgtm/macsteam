#!/bin/bash
# Test U1R16 static audit script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/u1r16-static-audit.sh"
TEST_DIR="$(mktemp -d /tmp/macsteam-audit-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

export GIT_PAGER=cat GIT_TERMINAL_PROMPT=0

# Test 1: clean fixture returns 0
CLEAN_DIR="$TEST_DIR/clean"
mkdir -p "$CLEAN_DIR/Sources/MacSteam/Views"
echo 'import SwiftUI' > "$CLEAN_DIR/Sources/MacSteam/Views/TestView.swift'
cd "$CLEAN_DIR"
git init -q && git add -A && git commit -q -m init 2>/dev/null
if bash "$AUDIT" >/dev/null 2>&1; then
    pass "clean fixture returns 0"
else
    fail "clean fixture should return 0"
fi

# Test 2: coordinator.state = detected
VIOL_DIR="$TEST_DIR/violation"
mkdir -p "$VIOL_DIR/Sources/MacSteam/Views"
echo 'coordinator.state = .steamReady' > "$VIOL_DIR/Sources/MacSteam/Views/TestView.swift"
cd "$VIOL_DIR"
git init -q && git add -A && git commit -q -m init 2>/dev/null
if bash "$AUDIT" >/dev/null 2>&1; then
    fail "coordinator.state = should be detected"
else
    pass "coordinator.state = detected"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Static audit test PASSED"
    exit 0
else
    echo "Static audit test FAILED — $FAILURES failure(s)"
    exit 1
fi
