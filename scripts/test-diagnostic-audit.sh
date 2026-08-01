#!/usr/bin/env bash
set -euo pipefail

FIXTURES="scripts/diagnostic-audit-fixtures"
PASS=0
FAIL=0

echo "=== Diagnostic Audit Fixture Harness ==="

# Violating fixture must contain detectable patterns
if grep -q "ProcessInfo.processInfo.environment" "$FIXTURES/violating.swift.fixture" && \
   grep -q "String(describing:" "$FIXTURES/violating.swift.fixture"; then
    echo "[PASS] Violating fixture contains expected bad patterns"
    PASS=$((PASS + 1))
else
    echo "[FAIL] Violating fixture missing expected bad patterns"
    FAIL=$((FAIL + 1))
fi

# Clean fixture must NOT contain bad patterns
if ! grep -q "ProcessInfo.processInfo.environment" "$FIXTURES/clean.swift.fixture" && \
   ! grep -q "String(describing:" "$FIXTURES/clean.swift.fixture"; then
    echo "[PASS] Clean fixture is free of bad patterns"
    PASS=$((PASS + 1))
else
    echo "[FAIL] Clean fixture contains bad patterns"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "Fixture harness passed."
