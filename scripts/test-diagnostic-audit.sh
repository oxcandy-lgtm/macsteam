#!/usr/bin/env bash
set -euo pipefail

DIAG_SOURCE="Sources/MacSteam/Diagnostics/DiagnosticBundle.swift"
COORD_SOURCE="Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift"
LIN_SOURCE="Sources/MacSteam/Sessions/HostProcessLineage.swift"
SUP_SOURCE="Sources/MacSteam/Sessions/ProcessSupervisor.swift"
GSS_SOURCE="Sources/MacSteam/Sessions/GameSessionSupervisor.swift"
BRINGUP_SOURCE="Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift"
LINETESTS_SOURCE="Tests/MacSteamTests/HostProcessLineageTests.swift"
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
    mkdir -p "$workdir/Sources/MacSteam/Sessions"
    mkdir -p "$workdir/Tests/MacSteamTests"
    cp "$DIAG_SOURCE" "$workdir/Sources/MacSteam/Diagnostics/"
    cp "$COORD_SOURCE" "$workdir/Sources/MacSteam/Ultimate/"
    cp "$LIN_SOURCE" "$workdir/Sources/MacSteam/Sessions/"
    cp "$SUP_SOURCE" "$workdir/Sources/MacSteam/Sessions/"
    cp "$GSS_SOURCE" "$workdir/Sources/MacSteam/Sessions/"
    cp "$BRINGUP_SOURCE" "$workdir/Tests/MacSteamTests/"
    cp "$LINETESTS_SOURCE" "$workdir/Tests/MacSteamTests/"

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
echo "=== U1R18 R4-FIX1 Mutation Fixtures ==="
echo ""

# 11. PID-only ownership (identity loses start microseconds)
run_mutation "pid-only-ownership" \
    "sed -i '' '/startMicroseconds/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 12. Name-guessed orphan admission reintroduced
run_mutation "name-only-orphan" \
    "echo 'let _ = rootSnap.identity.executableName == root.identity.executableName' >> Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 13. Root identity regenerated at census time (no launch capture)
run_mutation "census-time-root-regeneration" \
    "sed -i '' '/capturedRootIdentity/d' Sources/MacSteam/Sessions/ProcessSupervisor.swift" \
    "fail"

# 14. Unobserved orphan admission (ledger observation removed)
run_mutation "unobserved-orphan" \
    "sed -i '' 's/observed/observed_DISABLED/g' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 15. Provider failure → zero/proven hardcoded in coordinator
run_mutation "provider-failure-zero-proven" \
    "sed -i '' 's/WineProcessCensusDiagnostic(census: processCensus)/WineProcessCensusDiagnostic(hostProcessCount: 0, zombieCount: 0, orphanCount: 0, totalLive: 0, censusError: nil, hostProcessProof: \"proven\")/' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" \
    "fail"

# 16. Zombie/orphan accounting merged
run_mutation "zombie-orphan-merge" \
    "sed -i '' 's/liveOrphans/liveOrphans_MERGED/g' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 17. Zombie signaling reintroduced into census
run_mutation "zombie-signal" \
    "echo 'kill(0, SIGKILL)' >> Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 18. Raw PID output reintroduced into census
run_mutation "raw-pid-output" \
    "echo 'print(\"pid\")' >> Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 19. Coordinator calls static PID census directly
run_mutation "coordinator-static-census" \
    "echo 'let _ = HostProcessLineage.lineage(from: 0)' >> Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" \
    "fail"

# 20. Unbounded enumeration/ledger
run_mutation "unbounded-ledger" \
    "sed -i '' 's/maxCensusSize/maxCensusSize_UNBOUNDED/g' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 21. Stale session ledger reuse (ledger never cleared)
run_mutation "stale-ledger-reuse" \
    "sed -i '' '/censusLedger = nil/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# 22. Synthetic-only zombie proof (real-Mac gate removed)
run_mutation "synthetic-only-zombie-proof" \
    "sed -i '' 's/MACSTEAM_R1_BRINGUP/MACSTEAM_R1_BRINGUP_DISABLED/' Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

echo ""
echo "=== U1R18 R4-FIX2 Mutation Fixtures ==="
echo ""

# 23. Provider failure outcome collapsed (nil treated as exit)
run_mutation "provider-failure-removed" \
    "sed -i '' '/case providerFailure/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 24. Ambiguous/unresolved outcome permitted to be proven
run_mutation "ambiguous-permitted" \
    "sed -i '' '/providerOutcomeUnresolved/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 25. Truncated enumeration tolerated (no fail-closed)
run_mutation "truncation-tolerated" \
    "sed -i '' '/enumerationTruncated/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 26. Comm name substituted for canonical identity in the match
run_mutation "comm-name-substitute" \
    "sed -i '' 's/canonicalExecutable == other.canonicalExecutable/executableName == other.executableName/' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 27. Canonical executable removed from the identity match
run_mutation "canonical-removed" \
    "sed -i '' '/canonicalExecutable == other.canonicalExecutable/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 28. In-test direct ledger construction (violates the full-route requirement)
run_mutation "in-test-direct-ledger" \
    "echo 'let _ = ProcessCensusLedger(rootIdentity: root)' >> Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

# 29. In-test static census call (bypasses the supervised route)
run_mutation "in-test-static-census" \
    "echo 'let _ = HostProcessLineage.lineage(from: 0)' >> Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

# 30. Route bypass: supervsised processCensus removed from the bring-up route
run_mutation "route-bypass" \
    "sed -i '' '/supervisor.processCensus()/d' Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

# 31. Provider-failure fail-closed unit test deleted (non-bruting ambiguity cover)
run_mutation "provider-failure-test-deleted" \
    "sed -i '' '/fails closed on a provider failure outcome/d' Tests/MacSteamTests/HostProcessLineageTests.swift" \
    "fail"

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL mutation fixtures did not behave as expected."
    exit 1
fi
echo "All mutation fixtures passed."
