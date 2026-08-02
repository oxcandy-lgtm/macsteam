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
echo "=== U1R18 R4-FIX2 Provider Completeness / Canonical Identity / Route Audit ==="
echo ""

LINETESTS="Tests/MacSteamTests/HostProcessLineageTests.swift"

# 27. Every probe outcome is a first-class, explicitly-accounted case — a nil or
#     failed probe is never smuggled through as a silent exit.
grep -qE '^\s*case present' "$LIN"
check "Probe outcome present(snapshot) is an explicit case" $?
grep -qE '^\s*case confirmedExited' "$LIN"
check "Probe outcome confirmedExited is an explicit case" $?
grep -qE '^\s*case inaccessible' "$LIN"
check "Probe outcome inaccessible is an explicit case" $?
grep -qE '^\s*case providerFailure' "$LIN"
check "Probe outcome providerFailure is an explicit case" $?
# No single-nil-as-exit: existence is decided by the kernel, not by absence.
! grep -qE 'nil.*confirmedExited|confirmedExited.*nil' "$LIN"
check "A nil probe is never mistaken for a confirmed exit" $?

# 28. Ambiguous outcomes fail the census closed and are never counted as zero.
grep -qE '\bproviderOutcomeUnresolved\b' "$LIN"
check "Ambiguous provider outcome fails the census closed" $?
grep -qE '\benumerationTruncated\b' "$LIN"
check "Truncated enumeration fails the census closed" $?

# 29. Enumeration is a grow-based full scan with an explicit numerical bound, so
#     a census is either complete or fail-closed — never silently partial.
grep -qE '\bunresolvedOutcomes\b' "$LIN"
check "Census separates unresolved provider outcomes" $?
grep -qE '\bsilentSnapshotDrops\b' "$LIN"
check "Census separately accounts silent snapshot drops" $?

# 30. Canonical executable identity participates in the match (ownership is not
#     PID-only, and the comm name is never substituted for it).
grep -qE 'canonicalExecutable == other\.canonicalExecutable' "$LIN"
check "Canonical executable identity participates in the match" $?
! grep -qE 'executableName[^,]*(==|matches)|== other\.executableName' "$LIN"
check "Comm name is never substituted for canonical identity in the match" $?

# 31. Fail-closed persists for the full production census (not just lineage) and
#     the observed identity is retained on an ambiguous outcome.
grep -qE '\.incomplete\(\.providerOutcomeUnresolved|incomplete\(' "$LIN"
check "Ambiguous census record is fail-closed" $?

# 32. The real-Mac bring-up evidence stays on the FULL production route: it
#     never constructs the ledger or calls the static census directly, and it
#     drives through GameSessionSupervisor.processCensus to the bundle.
! grep -vE '^[[:space:]]*///' "$BRINGUP" | grep -qE 'ProcessCensusLedger\('
check "Bring-up evidence never constructs the ledger directly" $?
! grep -vE '^[[:space:]]*///' "$BRINGUP" | grep -qE 'HostProcessLineage\.'
check "Bring-up evidence never calls the static census directly" $?
grep -qE 'supervisor\.processCensus\(\)' "$BRINGUP"
check "Bring-up evidence routes via GameSessionSupervisor.processCensus" $?
grep -qE 'generateDiagnosticBundle' "$BRINGUP"
check "Bring-up evidence routes through coordinator bundle generation" $?

# 33. The provider-failure and inaccessible fail-closed unit tests exist and are
#     enforced statically (they are the non-bruting coverage of ambiguous
#     outcomes).
grep -qE 'fails closed when a probe is inaccessible' "$LINETESTS"
check "Inaccessible-outcome fail-closed unit test present" $?
grep -qE 'fails closed on a provider failure outcome' "$LINETESTS"
check "Provider-failure fail-closed unit test present" $?

echo ""
echo "=== U1R18 R4-FIX3 Canonical Fail-Closed / Coherent Snapshot / Identity-Bound Launch Audit ==="
echo ""

# 34. Live canonical executable is never empty and never substituted (comm /
#     basename / argv). An unprovable live identity is ambiguous, not present.
grep -qE 'presentOnlyIfProven' "$LIN"
check "Live empty-canonical is rejected by the provider (never present)" $?
grep -qE 'return \.inaccessible' "$LIN"
check "An unresolvable live canonical degrades to an ambiguous outcome" $?
! grep -vE '^[[:space:]]*//' "$LIN" | grep -qE 'executableName.*canonicalExecutable|comm.*canonical|basename.*canonical'
check "Comm / basename substitution for canonical is forbidden" $?

# 35. An empty canonical never satisfies an ownership match (empty==empty
#     forbidden).
grep -qE 'guard !canonicalExecutable.isEmpty' "$LIN"
check "Empty-canonical identity never matches (matches() guard)" $?

# 36. A zombie may inherit a previously captured non-empty canonical, but never
#     invents a replacement identity (inheritance requires the SAME PID and the
#     SAME start tuple).
grep -qE 'known.startSeconds == row.startSeconds' "$LIN"
check "Zombie inherits canonical only from a same-PID/start captured identity" $?

# 37. Root identity must be established at launch; otherwise the process is
#     terminated/reaped and all bookkeeping is removed before failing the launch
#     (no unproven handle/session/receipt/ledger is published).
grep -qE 'guard let rootIdentity = await processSupervisor.capturedRootIdentity' "$GSS"
check "Launch requires a captured root identity" $?
grep -qE 'requestForceKill|requestTerminate' "$GSS"
check "Identity-failure terminates the launched process" $?
grep -qE 'processSupervisor.discard' "$GSS"
check "Identity-failure deletes ProcessSupervisor bookkeeping" $?
grep -qE 'aborted to avoid an unproven session' "$GSS"
check "Identity failure bears the unproven-session abort guard" $?

# 38. Production census authority is a coherent native snapshot (single
#     KERN_PROC_ALL generation), NOT sequential PID probing.
grep -qE 'KERN_PROC_ALL' "$LIN"
check "Census uses a single-generation native table snapshot" $?
grep -qE 'func nativeTableSnapshot' "$LIN"
check "Native coherent table capture exists" $?
grep -qE 'NativeProcessRow' "$LIN"
check "Coherent row model (pid/ppid/state/start) exists" $?

# 39. Coherent topology gate: a second capture must match; otherwise bounded
#     retry, then fail closed as snapshotUnstable. An owned grandchild is never
#     dropped behind `proven`.
grep -qE 'snapshotUnstable' "$LIN"
check "Unstable snapshot fails closed (snapshotUnstable)" $?
grep -qE 'coherent = false' "$LIN"
check "A changed relevant row sets the coherence flag" $?
grep -qE 'if !coherent' "$LIN"
check "A second capture must match the first (coherence gate)" $?
grep -qE 'maxTableRetries' "$LIN"
check "Stability retry is explicitly bounded" $?
grep -qE 'case .snapshotUnstable' "$LIN"
check "snapshotUnstable is a first-class census error" $?
grep -qE 'grandchild_dropped_under_proven' "$BRINGUP"
check "Real-Mac race evidence asserts grandchild-never-dropped-under-proven" $?

echo ""
echo "=== U1R18 R4-FIX4 Unobserved-Zombie Fail-Closed / Retry Candidate Carryover / Reap Confirm Audit ==="
echo ""

# 46. Unobserved-zombie canonical fail-closed: an unobserved zombie (no prior
#     same-PID/start identity) whose canonical is unresolvable is ambiguous —
#     empty canonical is never `.present`, snapshotted, carried as candidate,
#     or placed into the ledger.
grep -qE 'snap.identity.canonicalExecutable.isEmpty' "$LIN"
check "Empty canonical is never present (unobserved zombie included)" $?
grep -qE 'if canonical.isEmpty \{' "$LIN"
check "Unresolvable rows revalidate in census, never admitted as empty" $?
grep -qE 'rootRow.state != .zombie && rootCanonical.isEmpty' "$LIN"
check "Root-empty-canonical fails closed" $?

# 47. Retry candidate carryover: identities discovered during an unstable
#     attempt are carried forward so a descendant once seen is never forgotten
#     on retry. The final stable resolve covers ledger ∪ reachable ∪ carried.
grep -qE 'carriedCandidates' "$LIN"
check "Unstable attempts carry forward discovered identities" $?
grep -qE '\.union\(carriedCandidates\.map' "$LIN"
check "Carried candidates join the resolution set on retry" $?
grep -qE 'carriedCandidates.count >= maxCensusSize' "$LIN"
check "Carried candidate count is explicitly bounded" $?
grep -qE 'for snap in snapshots.values where' "$LIN"
check "Unstable-attempt identities are carried forward on incoherence" $?

# 48. Reconcile resolves every carried candidate (descendant/orphan/exited/PID-
#     reuse) before granting provenance; a candidate is never silently dropped.
grep -qE 'considered\.append\(candidate\)' "$LIN"
check "Reconcile folds carried candidates into resolve" $?
grep -qE 'carriedCandidates: \[ProcessIdentity\] = \[\]' "$LIN"
check "Reconcile carries candidate resolution as the census authority" $?

# 49. Force-kill reap confirmation: SIGTERM -> bounded wait -> SIGKILL -> second
#     bounded wait confirm; unconfirmed reap never claims full rollback.
grep -qE 'terminateAndReapOwned' "$GSS"
check "A reap-confirmation path exists for owned processes" $?
grep -qE 'second bounded reap-wait' "$GSS"
check "SIGKILL is followed by a second reap-confirm wait" $?
grep -qE 'if confirmed \{' "$GSS"
check "Reap discard only after confirmed exit" $?
grep -qE 'recoveryRequired' "$GSS"
check "Unconfirmed reap falls to an explicit recovery state" $?
grep -qE 'coldStartReparentRace' "$BRINGUP"
check "Real-Mac cold-start reparent race evidence present" $?

echo ""
echo "=== U1R18 R4-FIX6 Stored Recovery Cleanup Transaction Audit (semantic) ==="
echo ""
# Every guard below matches a REAL control-flow statement / assignment / call —
# never a comment and never a bare identifier. Each is paired with a semantic
# mutation in test-diagnostic-audit.sh that breaks the actual behavior.

# S1. Reap-unconfirmed halt: a confirmed-reap gate that throws, so an
#     unconfirmed reap stops every later phase.
grep -qE 'guard confirmed else \{' "$GSS"
check "Unconfirmed reap is gated by a real guard-else throw" $?

# S2. Immediate persistence: the stored authority is written back after each
#     completed step (>= 3 real assignments), so progress survives a failure.
[ "$(grep -cE 'recoveryCleanup = authority' "$GSS")" -ge 3 ]
check "Completed cleanup progress is persisted to the stored authority immediately" $?

# S3. Authority-owned lock release at the terminal step (the authority's lock,
#     not the bare field).
grep -qE 'authority\.sessionLock\?\.release\(\)' "$GSS"
check "Terminal step releases the authority-owned lock" $?

# S4. Retry never re-runs a confirmed discard (real progress condition).
grep -qE '!authority\.processDiscarded' "$GSS"
check "Reap/discard phase is skipped once already discarded (no re-run on retry)" $?

# S5. Discard routed through the injected seam, reachable only after confirm.
grep -qE 'cleanupProcesses\.discard\(handle\)' "$GSS"
check "Discard goes through the cleanup process seam" $?

# S6. Wineserver shutdown routed through the seam.
grep -qE 'cleanupWineserver\.shutdownPrefix' "$GSS"
check "Wineserver shutdown goes through the cleanup seam" $?

# S7. Wineserver stopped-confirmation routed through the seam.
grep -qE 'cleanupWineserver\.isRunning' "$GSS"
check "Wineserver stopped-confirmation goes through the cleanup seam" $?

# S8. Authority cleared exactly once, at the terminal (never on a failed retry).
[ "$(grep -cE 'recoveryCleanup = nil' "$GSS")" -eq 1 ]
check "Authority is cleared exactly once, at the confirmed terminus" $?

# S9. The unconfirmed-reap halt throws a real stopIncomplete (not a silent return).
grep -qE 'cleanup halted before discard' "$GSS"
check "Unconfirmed reap throws stopIncomplete (halt is explicit)" $?

# S10. stop/force-stop derive teardown from the stored/derived authority, so a
#      nil activeSession never no-ops a needed cleanup.
grep -qE 'recoveryCleanup = currentCleanupAuthority\(\)' "$GSS"
check "Stop/force-stop seed the stored authority before the transaction" $?

# S11. Recovery rollback captures the authority (real construction) and keeps it.
grep -qE 'recoveryCleanup = RecoveryCleanupAuthority\(' "$GSS"
check "Recovery rollback constructs the retained authority" $?

# S12. Wineserver progress flag is a real persisted assignment.
grep -qE 'authority\.wineserverShutdown = true' "$GSS"
check "Wineserver-shutdown progress is recorded on the authority" $?

# S13. SIGKILL escalation is a real call in the reap path.
grep -qE 'cleanupProcesses\.requestForceKill' "$GSS"
check "Reap path escalates to SIGKILL through the seam" $?

# S14. Terminal state transition is a real assignment.
grep -qE 'state = \.stopped' "$GSS"
check "Cleanup reaches the terminal .stopped state" $?

# S15. No fake session/receipt for a failed launch (real abort guard retained).
grep -qE 'aborted to avoid an unproven session' "$GSS"
check "Failed launch never fabricates a session/receipt" $?

# S16. New launch is blocked while recovery is required (real launch gate).
grep -qE 'guard state == \.idle \|\| state == \.stopped' "$GSS"
check "Launch requires idle/stopped (recovery blocks new launch)" $?

# S17. Behavioral proof suite exists and drives the real stop/forceStop route.
FIX6TESTS="Tests/MacSteamTests/GameSessionSupervisorCleanupTests.swift"
grep -qE 'reap unconfirmed halts every subsequent phase' "$FIX6TESTS"
check "Behavioral test: reap-unconfirmed halts all phases" $?
grep -qE 'retry does not re-run confirmed TERM/KILL/discard' "$FIX6TESTS"
check "Behavioral test: retry does not re-run confirmed steps" $?
grep -qE 'cleanup proceeds from authority when activeSession is nil' "$FIX6TESTS"
check "Behavioral test: nil-session cleanup proceeds from authority" $?

# S18. Real-Mac SIGTERM-ignoring child cleanup evidence is gated + uses a real
#      C fixture that ignores SIGTERM.
FIX6MAC="Tests/MacSteamTests/U1R18R4FIX6RealMacCleanupTests.swift"
grep -qE 'MACSTEAM_R1_BRINGUP' "$FIX6MAC"
check "Real-Mac FIX6 cleanup evidence is MACSTEAM-gated" $?
grep -qE 'signal\(SIGTERM, ignore_term\)' "$FIX6MAC"
check "Real-Mac FIX6 fixture ignores SIGTERM" $?

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL blocking items must be resolved."
    exit 1
fi
echo "All diagnostic security guards passed."
