#!/usr/bin/env bash
set -euo pipefail

DIAG_SOURCE="Sources/MacSteam/Diagnostics/DiagnosticBundle.swift"
COORD_SOURCE="Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift"
AUDIT="scripts/diagnostic-security-audit.sh"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0

trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_mutation() {
    local label="$1"
    local mutation_cmd="$2"
    local expect_fail="$3"

    local workdir="$TMPDIR_BASE/$label"
    mkdir -p "$workdir/Sources/MacSteam/Diagnostics"
    mkdir -p "$workdir/Sources/MacSteam/Ultimate"
    cp "$DIAG_SOURCE" "$workdir/Sources/MacSteam/Diagnostics/"
    cp "$COORD_SOURCE" "$workdir/Sources/MacSteam/Ultimate/"

    (cd "$workdir" && eval "$mutation_cmd")

    local rc=0
    (cd "$workdir" && bash "$OLDPWD/$AUDIT" >/dev/null 2>&1) || rc=$?

    if [ "$expect_fail" = "fail" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "[PASS] Mutation '$label' correctly rejected (exit $rc)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] Mutation '$label' was NOT rejected (exit 0)"
            FAIL=$((FAIL + 1))
        fi
    else
        if [ "$rc" -eq 0 ]; then
            echo "[PASS] Clean source correctly accepted (exit 0)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] Clean source was rejected (exit $rc)"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "=== Diagnostic Audit Mutation Fixture Harness ==="
echo ""

# 0. Clean source must pass
run_mutation "clean" "true" "pass"

# 1. Environment enumeration
run_mutation "env-enumeration" \
    "sed -i '' 's/static func sanitize/let _ = ProcessInfo.processInfo.environment\n    static func sanitize/' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 2. env / printenv
run_mutation "env-printenv" \
    "echo 'let x = \"printenv\"' >> Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 3. String(describing:) → diagnostic DTO
run_mutation "string-describing" \
    "sed -i '' 's/DiagnosticRedactor.sanitize/String(describing: error)\n        DiagnosticRedactor.sanitize/' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 4. Arbitrary destination URL
run_mutation "arbitrary-url" \
    "echo 'let u = URL(fileURLWithPath: \"/tmp/x\")' >> Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 5. Write-time full-chain re-validation missing
run_mutation "no-fullchain-revalidation" \
    "sed -i '' '/revalidateBeforeWrite/d' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 6. Sanitizer bypass
run_mutation "sanitizer-bypass" \
    "sed -i '' 's/func sanitized()/func sanitized_DISABLED()/' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 7. Bounds missing
run_mutation "bounds-missing" \
    "sed -i '' 's/maxBundleBytes/maxBundleBytes_DISABLED/' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 8. Credential scan missing
run_mutation "credential-scan-missing" \
    "sed -i '' '/scanForCredentialAssignments/d' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 9. Tmp cleanup missing
run_mutation "tmp-cleanup-missing" \
    "sed -i '' '/removeItem(at: tempURL)/d' Sources/MacSteam/Diagnostics/DiagnosticBundle.swift" \
    "fail"

# 10. Caller-parent containment (no validatedTarget)
run_mutation "no-validated-target" \
    "sed -i '' 's/validatedTarget/validatedTarget_DISABLED/' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" \
    "fail"

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL mutation fixtures did not behave as expected."
    exit 1
fi
echo "All mutation fixtures passed."
