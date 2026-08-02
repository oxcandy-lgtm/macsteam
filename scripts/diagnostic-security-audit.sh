#!/usr/bin/env bash
set -euo pipefail

DIAG_DIR="Sources/MacSteam/Diagnostics"
COORD="Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift"
LIN="Sources/MacSteam/Sessions/HostProcessLineage.swift"
SUP="Sources/MacSteam/Sessions/ProcessSupervisor.swift"
GSS="Sources/MacSteam/Sessions/GameSessionSupervisor.swift"
BRINGUP="Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift"
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
echo "=== U1R18 R4-FIX1 Lineage / Census Ownership Audit ==="
echo ""

# 16. Identity is never PID-only: start seconds, start microseconds, and the
#     canonical executable identity are all part of ownership.
grep -qE '\bstartSeconds\b' "$LIN"
check "Identity includes startSeconds (no PID-only ownership)" $?
grep -qE '\bstartMicroseconds\b' "$LIN"
check "Identity includes startMicroseconds (no PID-only ownership)" $?
grep -qE '\bcanonicalExecutable\b' "$LIN"
check "Identity includes canonical executable (no PID-only ownership)" $?
grep -qE '\bfunc matches\b' "$LIN"
check "Stable-process comparison used for PID-reuse detection" $?

# 17. Root identity is captured at launch, never regenerated at census time.
grep -qE '\bcapturedRootIdentity\b' "$SUP"
check "ProcessSupervisor captures the launch root identity" $?
grep -qE '\brootIdentityByToken\b' "$SUP"
check "Captured identity is stored per launch token" $?
grep -q "censusLedger = ProcessCensusLedger" "$GSS"
check "Session ledger is seeded from the captured identity" $?

# 18. Coordinator never calls the static PID census directly (R6 route is via
#     sessionSupervisor).
! grep -q "HostProcessLineage" "$COORD"
check "Coordinator routes census via sessionSupervisor, not static PID census" $?
grep -q "func processCensus()" "$GSS"
check "GameSessionSupervising exposes processCensus()" $?

# 19. No name/executable guessing for orphans: orphans are admitted only from
#     the observed ledger. (The legitimate `matches()` identity comparison
#     compares against `other`, never against the root by name.)
! grep -qE 'executableName[^;]*root' "$LIN"
check "No name/executable-guessed orphan admission" $?
grep -qE '\bobserved\b' "$LIN"
check "Orphans admitted only from observed ledger entries" $?

# 20. Fail-closed census: provider failure never maps to a proven zero.
grep -qE '\bProcessCensusState\b' "$LIN"
check "Census carries an explicit proof state" $?
grep -qE '\bcase incomplete\b' "$LIN"
check "Fail-closed incomplete state exists" $?
grep -q "init(census:" "$DIAG_DIR/DiagnosticBundle.swift"
check "Proof derived from census state, not hardcoded" $?
! grep -q '"proven"' "$COORD"
check "Coordinator never hardcodes a proven proof string" $?

# 21. Separated accounting: live descendant / live orphan / zombie / exited /
#     PID-reuse are distinct counters.
grep -qE '\bliveDescendants\b' "$LIN"
check "Separated liveDescendants counter" $?
grep -qE '\bliveOrphans\b' "$LIN"
check "Separated liveOrphans counter" $?
grep -qE '\bzombieCount\b' "$LIN"
check "Separated zombieCount counter (never merged with orphans)" $?
grep -qE '\bexitedCount\b' "$LIN"
check "Separated exitedCount counter" $?
grep -qE '\bpidReuseCount\b' "$LIN"
check "Separated pidReuseCount counter" $?

# 22. Census never signals processes (zombies are never killed/terminated).
! grep -qE '\bkill\(|\.terminate\(|SIGKILL|SIGTERM|requestForceKill|requestTerminate' "$LIN"
check "Census performs no process signaling" $?

# 23. Census never emits raw PIDs/PPIDs/paths/argv.
! grep -qE '\bprint\(|NSLog|os_log|Logger\(' "$LIN"
check "Census emits no raw PID/PPID/path/argv output" $?

# 24. Ledger and enumeration are bounded.
grep -qE '\bmaxCensusSize\b' "$LIN"
check "Census enumeration is bounded" $?
grep -qE '\blimitExceeded\b' "$LIN"
check "Bound violation fails closed" $?

# 25. Stale session ledger reuse is prevented: the ledger is cleared whenever a
#     session starts or ends.
grep -q "censusLedger = nil" "$GSS"
check "Session ledger cleared on launch/stop (no stale reuse)" $?

# 26. Real-Mac zombie evidence is gated and uses a real C fixture — synthetic
#     enum-only zombie proof is prohibited.
grep -q 'MACSTEAM_R1_BRINGUP"]' "$BRINGUP"
check "Real-Mac census evidence suite is MACSTEAM-gated" $?
grep -q "clang" "$BRINGUP"
check "Real-Mac census evidence uses a real C zombie fixture" $?
grep -q "true_posix_zombie_observed" "$BRINGUP"
check "Real-Mac census evidence records mandatory zombie flag" $?

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL blocking items must be resolved."
    exit 1
fi
echo "All diagnostic security guards passed."
