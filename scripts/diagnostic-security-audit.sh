#!/usr/bin/env bash
set -euo pipefail

DIAG_DIR="Sources/MacSteam/Diagnostics"
COORD="Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift"
PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Diagnostic Security Audit ==="
echo ""

# 1. No ProcessInfo.processInfo.environment in diagnostics
! grep -rq "ProcessInfo.processInfo.environment" "$DIAG_DIR" 2>/dev/null
check "No environment access in diagnostics" $?

# 2. No env/printenv calls
! grep -rqE '\benv\b|\bprintenv\b' "$DIAG_DIR" 2>/dev/null
check "No env/printenv in diagnostics" $?

# 3. No String(describing:) in diagnostics
! grep -rq "String(describing:" "$DIAG_DIR" 2>/dev/null
check "No String(describing:) in diagnostics" $?

# 4. No arbitrary destination URL construction in diagnostics (trusted root NSHomeDirectory exempt)
! grep -v "NSHomeDirectory" "$DIAG_DIR/DiagnosticBundle.swift" | grep -v "fileURLWithPath: home" | grep -q "URL(fileURLWithPath:"
check "No arbitrary destination URL" $?

# 5. Root no-follow validation present
grep -q "validateFullPathChain" "$DIAG_DIR/DiagnosticBundle.swift"
check "Root no-follow validation present" $?

# 6. Symlink rejection present
grep -q "destinationOfSymbolicLink" "$DIAG_DIR/DiagnosticBundle.swift"
check "Symlink rejection present" $?

# 7. Tmp cleanup present
grep -q "removeItem(at: tempURL)" "$DIAG_DIR/DiagnosticBundle.swift"
check "Tmp cleanup on failure present" $?

# 8. Credential assignment scan present
grep -q "scanForCredentialAssignments" "$DIAG_DIR/DiagnosticBundle.swift"
check "Credential assignment scan present" $?

# 9. Size limits enforced (exact references, not renamed)
grep -qE '\bmaxBundleBytes\b' "$DIAG_DIR/DiagnosticBundle.swift"
check "Bundle size limit enforced" $?
grep -qE '\bmaxArrayElements\b' "$DIAG_DIR/DiagnosticBundle.swift"
check "Array size limit enforced" $?
grep -qE '\bmaxStringChars\b' "$DIAG_DIR/DiagnosticBundle.swift"
check "String size limit enforced" $?
grep -qE '\bmaxOutputLines\b' "$DIAG_DIR/DiagnosticBundle.swift"
check "Output line limit enforced" $?

# 10. Sanitizer applied to all strings (sanitized() method present)
grep -q "func sanitized()" "$DIAG_DIR/DiagnosticBundle.swift"
check "Bundle sanitized() method present" $?

# 11. Filename validation present
grep -q "validateFilename" "$DIAG_DIR/DiagnosticBundle.swift"
check "Filename validation present" $?

# 12. Control character rejection
grep -q "0x20" "$DIAG_DIR/DiagnosticBundle.swift"
check "Control character rejection present" $?

# 13. Re-validation before write
grep -q "revalidateBeforeWrite" "$DIAG_DIR/DiagnosticBundle.swift"
check "Re-validation before write present" $?

# 14. No String(describing:) for errors in coordinator diagnostic generation
! grep -A2 "generateDiagnosticBundle\|errorCase" "$COORD" | grep -q "String(describing:"
check "No String(describing: Error) in coordinator diagnostics" $?

# 15. Export authority uses validatedTarget (exact, not renamed)
grep -qE '\bvalidatedTarget\b' "$COORD"
check "Export authority uses validatedTarget" $?

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL blocking items must be resolved."
    exit 1
fi
echo "All diagnostic security guards passed."
