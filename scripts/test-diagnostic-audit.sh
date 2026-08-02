#!/usr/bin/env bash
set -euo pipefail

DIAG_SOURCE="Sources/MacSteam/Diagnostics/DiagnosticBundle.swift"
COORD_SOURCE="Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift"
LIN_SOURCE="Sources/MacSteam/Sessions/HostProcessLineage.swift"
SUP_SOURCE="Sources/MacSteam/Sessions/ProcessSupervisor.swift"
GSS_SOURCE="Sources/MacSteam/Sessions/GameSessionSupervisor.swift"
BRINGUP_SOURCE="Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift"
LINETESTS_SOURCE="Tests/MacSteamTests/HostProcessLineageTests.swift"
FIX6_CLEANUP_TESTS="Tests/MacSteamTests/GameSessionSupervisorCleanupTests.swift"
FIX6_MAC_TESTS="Tests/MacSteamTests/U1R18R4FIX6RealMacCleanupTests.swift"
APP_SOURCE="Sources/MacSteam/App/MacSteamApp.swift"
R5_MAC_TESTS="Tests/MacSteamTests/U1R18R5DockQuitCompleteZeroTests.swift"
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
    mkdir -p "$workdir/Sources/MacSteam/App"
    mkdir -p "$workdir/Tests/MacSteamTests"
    cp "$DIAG_SOURCE" "$workdir/Sources/MacSteam/Diagnostics/"
    cp "$COORD_SOURCE" "$workdir/Sources/MacSteam/Ultimate/"
    cp "$LIN_SOURCE" "$workdir/Sources/MacSteam/Sessions/"
    cp "$SUP_SOURCE" "$workdir/Sources/MacSteam/Sessions/"
    cp "$GSS_SOURCE" "$workdir/Sources/MacSteam/Sessions/"
    cp "$APP_SOURCE" "$workdir/Sources/MacSteam/App/"
    cp "$BRINGUP_SOURCE" "$workdir/Tests/MacSteamTests/"
    cp "$LINETESTS_SOURCE" "$workdir/Tests/MacSteamTests/"
    cp "$FIX6_CLEANUP_TESTS" "$workdir/Tests/MacSteamTests/"
    cp "$FIX6_MAC_TESTS" "$workdir/Tests/MacSteamTests/"
    cp "$R5_MAC_TESTS" "$workdir/Tests/MacSteamTests/"

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
echo "=== U1R18 R4-FIX3 Mutation Fixtures ==="
echo ""

# 32. Empty canonical probed as .present (fail-closed guard removed)
run_mutation "empty-canonical-present" \
    "sed -i '' '/presentOnlyIfProven/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 33. Empty==empty canonical match permitted (guard removed)
run_mutation "empty-canonical-match" \
    "sed -i '' '/guard !canonicalExecutable.isEmpty/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 34. comm fallback to satisfy canonical identity
run_mutation "comm-canonical-fallback" \
    "echo 'let _ = identity.executableName == canonicalExecutable' >> Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 35. root identity failure allowed to continue launch (guard removed)
run_mutation "identity-failure-launch-continues" \
    "sed -i '' '/aborted to avoid an unproven session/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# 36. identity-failure cleanup removed (process not terminated/reaped)
run_mutation "identity-failure-cleanup-missing" \
    "sed -i '' '/processSupervisor.discard/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# 37. unobserved/zombie identity fabrication: inherit without the same start
#     tuple (a zombie may then claim an unrelated process's canonical)
run_mutation "zombie-identity-fabrication" \
    "sed -i '' '/known.startSeconds == row.startSeconds/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 38. regression to sequential PID topology (native snapshot removed)
run_mutation "sequential-pid-topology" \
    "sed -i '' '/KERN_PROC_ALL/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 39. mixed snapshot generation (coherence gate removed)
run_mutation "mixed-snapshot-generation" \
    "sed -i '' '/!coherent {/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 40. candidate disappearance treated as normal exit (instability removed)
run_mutation "candidate-disappearance-as-exit" \
    "sed -i '' '/snapshotUnstable/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 41. stability retry removed (bounded retries deleted)
run_mutation "stability-retry-removed" \
    "sed -i '' '/maxTableRetries/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 42. retry failure still proven (retry cap removed)
run_mutation "retry-cap-removed" \
    "sed -i '' 's/snapshotUnstable/proven/g' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 43. ledger mutation before stability confirmed (reconcile before coherence gate)
run_mutation "ledger-mutated-before-stable" \
    "sed -i '' '/coherent = true/,+5d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 44. race test removed (grandchild-never-dropped invariant)
run_mutation "race-race-test-removed" \
    "sed -i '' '/grandchild_dropped_under_proven/d' Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

# 45. real-Mac route bypass (supervisor.processCensus replaced)
run_mutation "route-bypass-fix3" \
    "sed -i '' 's/supervisor.processCensus()/HostProcessLineage.census(ledger: \&ledger)/' Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

# 57. unobserved zombie + empty canonical admitted as present
run_mutation "unobserved-zombie-empty-present" \
    "sed -i '' 's/if snap.identity.canonicalExecutable.isEmpty {/if snap.isZombie {/' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 58. empty canonical leaked into the retry candidate set
run_mutation "empty-canonical-candidate-mix" \
    "sed -i '' 's/if canonical.isEmpty {/if row.state != .zombie \&\& canonical.isEmpty {/' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 59. retry candidate authority removed (no carry-over device)
run_mutation "retry-candidate-authority-removed" \
    "sed -i '' '/carriedCandidates/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 60. carry-in / next-attempt relevant set excludes the candidate
run_mutation "candidate-excluded-from-relevant" \
    "sed -i '' '/\.union(carriedCandidates\.map/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 61. candidates removed between attempts (snapshot.values loop deleted)
run_mutation "candidate-cleared-between-attempts" \
    "sed -i '' '/for snap in snapshots.values where/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 62. candidate silent drop in reconcile (no append of candidate)
run_mutation "candidate-silent-drop" \
    "sed -i '' '/considered\.append(candidate)/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 63. candidate upper limit removed
run_mutation "candidate-limit-removed" \
    "sed -i '' '/carriedCandidates.count >= maxCensusSize/d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 64. ledger updated before stability confirmed (stable retry removed)
run_mutation "ledger-updated-before-stable" \
    "sed -i '' '/if !coherent {/,+12d' Sources/MacSteam/Sessions/HostProcessLineage.swift" \
    "fail"

# 65. SIGKILL second wait removed (single wait then rollover)
run_mutation "sigkill-second-wait-removed" \
    "sed -i '' '/second bounded reap-wait/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# 66. reap-before-discard removed (discard before confirming reap)
run_mutation "reap-before-discard-removed" \
    "sed -i '' '/if confirmed/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# 67. forced-kill unconfirmed treated as rollback success (no second wait)
run_mutation "force-kill-unconfirmed-as-rollback" \
    "sed -i '' '/terminateAndReapOwned/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# 68. real-Mac test regressed to a pre-registered grandchild (removes FIX4 cold start)
run_mutation "real-mac-pre-registered-regression" \
    "sed -i '' '/coldStartReparentRace/d' Tests/MacSteamTests/U1R18ProcessCensusBringUpTests.swift" \
    "fail"

echo ""
echo "=== U1R18 R4-FIX6 Stored Recovery Cleanup Transaction Mutation Fixtures (semantic) ==="
echo ""
# Each mutation breaks a REAL control-flow statement; the paired semantic audit
# guard (S1..S14) rejects it. No mutation targets a comment or a bare identifier.

# M1 (S1): reap-unconfirmed halt removed — the guard-else throw is gone, so an
#     unconfirmed reap would fall through to discard/wineserver/lock-release.
run_mutation "fix6-unconfirmed-halt-removed" \
    "sed -i '' '/guard confirmed else {/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M2 (S2): immediate persistence removed — completed progress is never written
#     back to the stored authority.
run_mutation "fix6-immediate-persistence-removed" \
    "sed -i '' '/recoveryCleanup = authority/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M3 (S3): authority-owned lock release regressed to the bare field release.
run_mutation "fix6-field-lock-release" \
    "sed -i '' 's/authority.sessionLock?.release()/sessionLock?.release()/' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M4 (S4): retry re-runs a confirmed discard (progress condition removed).
run_mutation "fix6-retry-reruns-discard" \
    "sed -i '' 's/!authority.processDiscarded/true/' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M5 (S5): discard step removed from the seam.
run_mutation "fix6-discard-removed" \
    "sed -i '' '/cleanupProcesses.discard(handle)/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M6 (S6): wineserver shutdown removed.
run_mutation "fix6-wineserver-shutdown-removed" \
    "sed -i '' '/cleanupWineserver.shutdownPrefix/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M7 (S7): wineserver stopped-confirmation removed.
run_mutation "fix6-wineserver-confirm-removed" \
    "sed -i '' '/cleanupWineserver.isRunning/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M8 (S8): authority never cleared at the terminal (terminal clear removed).
run_mutation "fix6-terminal-clear-removed" \
    "sed -i '' '/recoveryCleanup = nil/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M9 (S9): unconfirmed-reap halt becomes a silent path (explicit throw removed).
run_mutation "fix6-silent-unconfirmed-path" \
    "sed -i '' '/cleanup halted before discard/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M10 (S10): stop/force-stop no-op on nil activeSession again (authority seeding
#      removed) — now targets the FIX7 `recoveryCleanup = authority` assignment.
run_mutation "fix6-nil-session-noop" \
    "sed -i '' '/recoveryCleanup = authority$/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M11 (S11): recovery rollback no longer captures the retained authority.
run_mutation "fix6-rollback-no-authority" \
    "sed -i '' '/recoveryCleanup = RecoveryCleanupAuthority(/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M12 (S12): wineserver-shutdown progress no longer recorded on the authority.
run_mutation "fix6-wineserver-progress-unrecorded" \
    "sed -i '' '/authority.wineserverShutdown = true/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M13 (S13): SIGKILL escalation removed from the reap path.
run_mutation "fix6-sigkill-escalation-removed" \
    "sed -i '' '/cleanupProcesses.requestForceKill/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# M14 (S14): terminal .stopped transition removed.
run_mutation "fix6-terminal-state-removed" \
    "sed -i '' '/state = .stopped/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# ---------------------------------------------------------------------------
# U1R18 R4-FIX7: State Idempotence mutations (semantic, state/ordering-aware).
# Each breaks a REAL control-flow statement; the paired F1..F5 guard rejects it.
# These are NOT comment/identifier/target-count tricks — a count-only false
# green is caught because the guards are state/ordering checks.
# ---------------------------------------------------------------------------

# MF1 (F1): the authority early-return is deleted, so `state = .stopping` is
#     now reached unconditionally — a stale .stopping after a no-op stop().
run_mutation "fix7-authority-guard-deleted" \
    "sed -i '' '/guard let authority = currentCleanupAuthority() else { return }/d' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# MF2 (F2): the early return is emptied (`else { return }` -> `else { }`), so the
#     no-authority path falls through and mutates state. Count-only green: the
#     `else { return }` literal count drops to 0, and F1's awk still flags the
#     unguarded assignment.
run_mutation "fix7-empty-else-state-break" \
    "sed -i '' 's/else { return }/else { }/g' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# MF3 (F3): the terminal transition is made stale (.stopped -> .stopping), so the
#     supervisor never lands on .stopped and a later launch stays blocked.
run_mutation "fix7-stale-stopping-not-stopped" \
    "sed -i '' 's/state = .stopped/state = .stopping/' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# MF4 (F4): the authority-derivation function is renamed, so a nil authority can
#     no longer be short-circuited out (derivation seam gone).
run_mutation "fix7-authority-function-renamed" \
    "sed -i '' 's/func currentCleanupAuthority/func resolveCleanupAuthority/' Sources/MacSteam/Sessions/GameSessionSupervisor.swift" \
    "fail"

# MF5 (F5): one of the behavioral state-idempotence assertions is removed, so a
#     count-only false green (state preserved in code but not asserted) passes;
#     the F5 fixture-name grep rejects it.
run_mutation "fix7-idempotence-test-removed" \
    "sed -i '' '/stop re-run after completion is a zero-side-effect no-op/d' Tests/MacSteamTests/GameSessionSupervisorCleanupTests.swift" \
    "fail"

# ---------------------------------------------------------------------------
# U1R18 R5 Dock Quit COMPLETE_ZERO / exact-once mutation fixtures.
# Each breaks a REAL statement in the Dock Quit path; the paired R5.F1..F5
# guard rejects it. No comment/identifier/count-only tricks.
# ---------------------------------------------------------------------------

# MR5.1 (R5.F1): the exact-once re-entrant no-op is deleted, so a second
#     Dock-Quit spawns a second cleanup Task and may reply twice.
run_mutation "dockquit-exact-once-guard-deleted" \
    "sed -i '' '/if terminationTransactionStarted { return .terminateLater }/d' Sources/MacSteam/App/MacSteamApp.swift" \
    "fail"

# MR5.2 (R5.F2): the affirmative reply is emitted from BOTH branches by making
#     the incomplete path also reply(true), so the count of reply(true) > 1.
run_mutation "dockquit-double-affirmative-reply" \
    "sed -i '' 's/sender.reply(toApplicationShouldTerminate: false)/sender.reply(toApplicationShouldTerminate: true)/' Sources/MacSteam/App/MacSteamApp.swift" \
    "fail"

# MR5.3 (R5.F3): the lock release is removed from the clean path, so reply(true)
#     no longer strictly follows release — the lock could leak past the quit.
run_mutation "dockquit-release-before-reply-removed" \
    "sed -i '' '/context.instanceGuard.release()/d' Sources/MacSteam/App/MacSteamApp.swift" \
    "fail"

# MR5.4 (R5.F4): the abort-on-incomplete reply(false) line is removed, so an
#     incomplete cleanup has no abort path (R5.F4 fixture gone); distinct from
#     MR5.2 which keeps the count guard violated.
run_mutation "dockquit-abort-reply-removed" \
    "sed -i '' '/sender.reply(toApplicationShouldTerminate: false)/d' Sources/MacSteam/App/MacSteamApp.swift" \
    "fail"

# MR5.5 (R5.F5): the real-Mac zero-residue host-process assertion is removed
#     (full #expect range, so its message vanishes too), so a non-zero host
#     census after quit would pass undetected.
run_mutation "dockquit-host-process-zero-proof-removed" \
    "sed -i '' '/windowsProcesses.total == 0/,/no host processes may remain/d' Tests/MacSteamTests/U1R18R5DockQuitCompleteZeroTests.swift" \
    "fail"

# MR5.6 (R5.F5): the re-entrant Dock-Quit exact-once no-op assertion is removed
#     (full #expect range), so a second reply/lock-release on double Cmd-Q
#     would go unproven.
run_mutation "dockquit-exact-once-noop-proof-removed" \
    "sed -i '' '/reentrantReply == .terminateLater/,/exact-once no-op/d' Tests/MacSteamTests/U1R18R5DockQuitCompleteZeroTests.swift" \
    "fail"

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL mutation fixtures did not behave as expected."
    exit 1
fi
echo "All mutation fixtures passed."
