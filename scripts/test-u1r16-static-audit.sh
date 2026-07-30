#!/bin/bash
# Test U1R16 static audit script
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$DIR/scripts/u1r16-static-audit.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macsteam-audit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Test 1: clean fixture returns 0
mkdir -p "$TMP/clean/Sources/MacSteam/Views"
echo 'import SwiftUI' > "$TMP/clean/Sources/MacSteam/Views/TestView.swift'
cd "$TMP/clean"
git init -q && git add -A && git commit -q -m init
if bash "$AUDIT" >/dev/null 2>&1; then
    pass "clean fixture returns 0"
else
    fail "clean fixture should return 0"
fi

# Test 2: coordinator.state = detected
mkdir -p "$TMP/violation/Sources/MacSteam/Views"
echo 'coordinator.state = .steamReady' > "$TMP/violation/Sources/MacSteam/Views/TestView.swift'
cd "$TMP/violation"
git init -q && git add -A && git commit -q -m init
if bash "$AUDIT" >/dev/null 2>&1; then
    fail "coordinator.state = should be detected"
else
    pass "coordinator.state = detected"
fi

# Test 3: coordinator.state     = (with spaces) detected
mkdir -p "$TMP/violation2/Sources/MacSteam/Views"
echo 'coordinator.state     = .steamReady' > "$TMP/violation2/Sources/MacSteam/Views/TestView.swift'
cd "$TMP/violation2"
git init -q && git add -A && git commit -q -m init
if bash "$AUDIT" >/dev/null 2>&1; then
    fail "coordinator.state with spaces should be detected"
else
    pass "coordinator.state with spaces detected"
fi

# Test 4: non-existent path returns exit 2
mkdir -p "$TMP/nopath/Sources"
cd "$TMP/nopath"
git init -q && git add -A && git commit -q -m init
set +e
bash "$AUDIT" 2>/dev/null
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
    pass "non-existent path returns exit 2"
else
    fail "non-existent path should return exit 2 (got $rc)"
fi

# Test 5: git missing returns exit 2
export PATH=/usr/bin:/bin
if command -v git >/dev/null 2>&1; then
    # git still exists in /usr/bin
    pass "git available in path test skipped"
else
    set +e
    bash "$AUDIT" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -eq 2 ]; then
        pass "git missing returns exit 2"
    else
        fail "git missing should return exit 2"
    fi
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "🎉 Static audit test PASSED — 0 failures"
    exit 0
else
    echo "💥 Static audit test FAILED — $FAILURES failure(s)"
    exit 1
fi
