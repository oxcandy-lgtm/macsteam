#!/bin/bash
# U1R16-R1F29 Static Audit Fixture — temporary git repo
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/u1r16-static-audit.sh"
FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Build a temporary git repo with fixture files
FIXTURE="$(mktemp -d /tmp/macsteam-audit-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

mk_repo() {
    local name="$1"
    local dir="$FIXTURE/$name"
    mkdir -p "$dir/Sources/MacSteam/Core"
    mkdir -p "$dir/Sources/MacSteam/Processes"
    (cd "$dir" && git init && git config user.email test@test && git config user.name test)
    echo "$name" > "$dir/README.md"
    (cd "$dir" && git add README.md)
}

add_file() {
    local repo="$1" path="$2" content="$3"
    mkdir -p "$FIXTURE/$repo/$(dirname "$path")"
    echo "$content" > "$FIXTURE/$repo/$path"
    (cd "$FIXTURE/$repo" && git add "$path" && git commit -m "add $path" --allow-empty)
}

run_audit() {
    local repo="$1" label="$2" expected="$3"
    local rc=0
    GIT_WORK_TREE="$FIXTURE/$repo" GIT_DIR="$FIXTURE/$repo/.git" bash "$AUDIT" --process-runner-only >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $rc)"
    fi
}

run_audit_cleanup() {
    local repo="$1" label="$2" expected="$3"
    local rc=0
    GIT_WORK_TREE="$FIXTURE/$repo" GIT_DIR="$FIXTURE/$repo/.git" bash "$AUDIT" --cleanup-only >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $rc)"
    fi
}

run_audit_lifecycle() {
    local repo="$1" label="$2" expected="$3"
    local rc=0
    GIT_WORK_TREE="$FIXTURE/$repo" GIT_DIR="$FIXTURE/$repo/.git" bash "$AUDIT" --ultimate-lifecycle-only >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $rc)"
    fi
}

# ── Fixtures ──

mk_repo "clean"
add_file "clean" "Sources/MacSteam/Core/ProcessRunner.swift" '
import Foundation
actor ProcessRunner { func run() {} }
'
add_file "clean" "Sources/MacSteam/Core/BoundedPipeCapture.swift" '
final class BoundedPipeCapture {}
'
run_audit "clean" "clean fixture" 0

mk_repo "readToEnd"
add_file "readToEnd" "Sources/MacSteam/Core/ProcessRunner.swift" '
let x = readToEnd()
'
add_file "readToEnd" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "readToEnd" "readToEnd fixture" 1

mk_repo "waitUntilExit"
add_file "waitUntilExit" "Sources/MacSteam/Core/ProcessRunner.swift" '
p.waitUntilExit()
'
add_file "waitUntilExit" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "waitUntilExit" "waitUntilExit fixture" 1

mk_repo "threadSafeData"
add_file "threadSafeData" "Sources/MacSteam/Core/ProcessRunner.swift" '
let d = ThreadSafeData()
'
add_file "threadSafeData" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "threadSafeData" "ThreadSafeData fixture" 1

mk_repo "directKill"
add_file "directKill" "Sources/MacSteam/Core/ProcessRunner.swift" '
kill(pid, SIGTERM)
'
add_file "directKill" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "directKill" "direct kill fixture" 1

mk_repo "optionalIdentity"
add_file "optionalIdentity" "Sources/MacSteam/Core/ProcessRunner.swift" '
let x = try? identityProvider.identity(forPID: 0)
'
add_file "optionalIdentity" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "optionalIdentity" "try? identityProvider fixture" 1

mk_repo "optionalWait"
add_file "optionalWait" "Sources/MacSteam/Core/ProcessRunner.swift" '
let x = try? await termCtrl.wait(until: nil)
'
add_file "optionalWait" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "optionalWait" "try? termCtrl.wait fixture" 1

mk_repo "ordinaryTry"
add_file "ordinaryTry" "Sources/MacSteam/Core/ProcessRunner.swift" '
do { let x = try something() } catch {}
'
add_file "ordinaryTry" "Sources/MacSteam/Core/BoundedPipeCapture.swift" ''
run_audit "ordinaryTry" "ordinary try fixture (should be 0)" 0

# Test 8: audit infrastructure failure (fake git that exits 2)
INFRA_DIR="$FIXTURE/infra"
mkdir -p "$INFRA_DIR/Sources/MacSteam/Core"
echo "let x = true" > "$INFRA_DIR/Sources/MacSteam/Core/ProcessRunner.swift"
echo "" > "$INFRA_DIR/Sources/MacSteam/Core/BoundedPipeCapture.swift"
mkdir -p "$INFRA_DIR/fakebin"
cat > "$INFRA_DIR/fakebin/git" << 'GITEOF'
#!/bin/bash
exit 2
GITEOF
chmod +x "$INFRA_DIR/fakebin/git"
cd "$INFRA_DIR"
# Run audit with fake git in PATH — infrastructure failure exits 2
PATH="$INFRA_DIR/fakebin:$PATH" GIT_WORK_TREE="$INFRA_DIR" GIT_DIR="$INFRA_DIR/.git" \
  bash "$AUDIT" --process-runner-only >/dev/null 2>&1 && rc=$? || rc=$?
[ "$rc" -eq 2 ] && pass "infrastructure failure exits 2" || fail "infra failure should be exit 2, got $rc"
cd "$SCRIPT_DIR/.."

# Test 9-15: Cleanup scope fixtures (--cleanup-only)
mk_repo "cleanup_clean"
add_file "cleanup_clean" "Sources/MacSteam/Installer/InstallerSupervisor.swift" 'true'
add_file "cleanup_clean" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" 'func foo() -> Bool { return true }'
add_file "cleanup_clean" "Sources/MacSteam/Processes/WineControlLane.swift" '
func wineserverProbe(wineserverURL: URL, prefixURL: URL) async throws -> Bool {
    let result = try await ProcessRunner().run(executable: wineserverURL, arguments: ["-p"], environment: ["WINEPREFIX": prefixURL.path], timeout: 5)
    guard result.exitCode == 0 else { throw WineControlError.wineserverFailed(exitCode: result.exitCode) }
    return !result.stdout.isEmpty
}'
run_audit_cleanup "cleanup_clean" "clean cleanup fixture" 0

mk_repo "cleanup_tryopt"
add_file "cleanup_tryopt" "Sources/MacSteam/Installer/InstallerSupervisor.swift" 'try? Task.sleep(for: .seconds(1))'
add_file "cleanup_tryopt" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" 'let x = try? await foo()'
add_file "cleanup_tryopt" "Sources/MacSteam/Processes/WineControlLane.swift" ''
run_audit_cleanup "cleanup_tryopt" "try? detection fixture" 1

mk_repo "cleanup_nohandle"
add_file "cleanup_nohandle" "Sources/MacSteam/Installer/InstallerSupervisor.swift" 'guard activeHandle else { return }'
add_file "cleanup_nohandle" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" ''
add_file "cleanup_nohandle" "Sources/MacSteam/Processes/WineControlLane.swift" ''
run_audit_cleanup "cleanup_nohandle" "no-handle early return fixture" 1

mk_repo "cleanup_concrete"
add_file "cleanup_concrete" "Sources/MacSteam/Installer/InstallerSupervisor.swift" 'private let processSupervisor: ProcessSupervisor'
add_file "cleanup_concrete" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" ''
add_file "cleanup_concrete" "Sources/MacSteam/Processes/WineControlLane.swift" ''
run_audit_cleanup "cleanup_concrete" "concrete supervisor dependency fixture" 1

mk_repo "cleanup_clock"
add_file "cleanup_clock" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" 'ContinuousClock.now'
add_file "cleanup_clock" "Sources/MacSteam/Installer/InstallerSupervisor.swift" ''
add_file "cleanup_clock" "Sources/MacSteam/Processes/WineControlLane.swift" ''
run_audit_cleanup "cleanup_clock" "clock-based poll fixture" 1

# Test: cleanup_probe — wineserverProbe without exitCode guard (violation expected)
mk_repo "cleanup_probe"
add_file "cleanup_probe" "Sources/MacSteam/Processes/WineControlLane.swift" '
func wineserverProbe(wineserverURL: URL, prefixURL: URL) async throws -> Bool {
    let result = try await ProcessRunner().run(executable: wineserverURL, arguments: ["-p"], environment: ["WINEPREFIX": prefixURL.path], timeout: 5)
    return !result.stdout.isEmpty
}'
add_file "cleanup_probe" "Sources/MacSteam/Installer/InstallerSupervisor.swift" ''
add_file "cleanup_probe" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" ''
run_audit_cleanup "cleanup_probe" "probe exitCode ignored fixture" 1

# Test: cleanup_probe_clean — wineserverProbe WITH exitCode guard (no violation)
mk_repo "cleanup_probe_clean"
add_file "cleanup_probe_clean" "Sources/MacSteam/Installer/InstallerSupervisor.swift" ''
add_file "cleanup_probe_clean" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" ''
add_file "cleanup_probe_clean" "Sources/MacSteam/Processes/WineControlLane.swift" '
func wineserverProbe(wineserverURL: URL, prefixURL: URL) async throws -> Bool {
    let result = try await ProcessRunner().run(executable: wineserverURL, arguments: ["-p"], environment: ["WINEPREFIX": prefixURL.path], timeout: 5)
    guard result.exitCode == 0 else { throw WineControlError.wineserverFailed(exitCode: result.exitCode) }
    return !result.stdout.isEmpty
}'
run_audit_cleanup "cleanup_probe_clean" "probe exitCode guarded fixture" 0

# Test: cleanup_probe_missing — wineserverProbe function absent (violation expected)
mk_repo "cleanup_probe_missing"
add_file "cleanup_probe_missing" "Sources/MacSteam/Processes/WineControlLane.swift" 'func unrelated() -> Bool { return true }'
add_file "cleanup_probe_missing" "Sources/MacSteam/Installer/InstallerSupervisor.swift" ''
add_file "cleanup_probe_missing" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" ''
run_audit_cleanup "cleanup_probe_missing" "wineserverProbe missing fixture" 1

# Test: cleanup_directpr — direct ProcessRunner() use in PrefixProcessTerminator (violation expected)
mk_repo "cleanup_directpr"
add_file "cleanup_directpr" "Sources/MacSteam/Processes/PrefixProcessTerminator.swift" 'let x = ProcessRunner()'
add_file "cleanup_directpr" "Sources/MacSteam/Installer/InstallerSupervisor.swift" ''
add_file "cleanup_directpr" "Sources/MacSteam/Processes/WineControlLane.swift" ''
run_audit_cleanup "cleanup_directpr" "direct ProcessRunner fixture" 1

# ── Ultimate lifecycle fixtures ──

# clean supervised lifecycle → 0 (has supervisedSession guard → check passes)
mk_repo "lifecycle_clean"
add_file "lifecycle_clean" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" ''
add_file "lifecycle_clean" "Sources/MacSteam/Sessions/GameSessionSupervisor.swift" 'actor GameSessionSupervisor { static func validateSessionPlan(_ plan: LaunchPlan) throws { guard case .supervisedSession = plan.mode else { throw SessionSupervisorError.validationFailed("") } } func launch(plan: LaunchPlan) { try Self.validateSessionPlan(plan) } }'
run_audit_lifecycle "lifecycle_clean" "clean supervised lifecycle" 0

# detached Steam launch → 1
mk_repo "lifecycle_detached"
add_file "lifecycle_detached" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" 'mode: .detached'
run_audit_lifecycle "lifecycle_detached" "detached Steam launch" 1

# try? session stop → 1
mk_repo "lifecycle_trysession"
add_file "lifecycle_trysession" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" 'try? await sessionSupervisor.stop()'
run_audit_lifecycle "lifecycle_trysession" "try? session stop" 1

# missing session mode validation → 1 (plan.mode referenced without supervisedSession guard)
mk_repo "lifecycle_novalid"
add_file "lifecycle_novalid" "Sources/MacSteam/Sessions/GameSessionSupervisor.swift" 'actor GameSessionSupervisor { func launch(plan: LaunchPlan) { let mode = plan.mode } }'
run_audit_lifecycle "lifecycle_novalid" "missing session mode validation" 1

# ── Diagnostic log redaction fixtures ──

run_audit_diagnostic() {
    local repo="$1" label="$2" expected="$3"
    local rc=0
    GIT_WORK_TREE="$FIXTURE/$repo" GIT_DIR="$FIXTURE/$repo/.git" bash "$AUDIT" --diagnostic-log-redaction-only >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $rc)"
    fi
}

# clean → 0 (no raw error logging, fixed stage message without colon)
mk_repo "diag_clean"
add_file "diag_clean" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" 'log("Installer cleanup failed")'
run_audit_diagnostic "diag_clean" "clean diagnostic log" 0

# direct log of error.localizedDescription → 1
mk_repo "diag_direct"
add_file "diag_direct" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" 'log("Installer cleanup failed: \(error.localizedDescription)")'
run_audit_diagnostic "diag_direct" "direct error log" 1

# indirect log via 1-hop alias → 1
mk_repo "diag_indirect"
add_file "diag_indirect" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
let detail = error.localizedDescription
log("Installer cleanup failed: \(detail)")
'
run_audit_diagnostic "diag_indirect" "indirect error log" 1

# unused alias → 0 (alias created but never logged)
mk_repo "diag_unused_alias"
add_file "diag_unused_alias" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
let detail = error.localizedDescription
log("Installer cleanup failed")
'
run_audit_diagnostic "diag_unused_alias" "unused alias log" 0

# ── Navigation authority guard fixtures ──

run_audit_navguard() {
    local repo="$1" label="$2" expected="$3"
    local rc=0
    GIT_WORK_TREE="$FIXTURE/$repo" GIT_DIR="$FIXTURE/$repo/.git" bash "$AUDIT" --navigation-guards-only >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $rc)"
    fi
}

# clean → 0 (correct single-authority wiring)
mk_repo "nav_clean"
add_file "nav_clean" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    @ViewBuilder
    var content: some View {
        switch UltimatePageResolver.contentKind(for: coordinator.currentPage) {
        case .steamInstaller: EmptyView()
        case .steamClient: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View { InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: .diagnostics, onNavigate: { _ in }) }
}
'
add_file "nav_clean" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool { true }
    func computePageCompletion() -> [String: Bool] { ["environment": canonicalPrefixEvidenceValid] }
}
'
run_audit_navguard "nav_clean" "clean navigation guards" 0

# root dispatch on coordinator.state → 1
mk_repo "nav_root_state"
add_file "nav_root_state" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    @ViewBuilder
    var content: some View {
        switch coordinator.state { default: EmptyView() }
    }
}
'
run_audit_navguard "nav_root_state" "root dispatch on state" 1

# merged Steam pages → 1
mk_repo "nav_merged_steam"
add_file "nav_merged_steam" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    @ViewBuilder
    var content: some View {
        switch UltimatePageResolver.contentKind(for: coordinator.currentPage) {
        case .steamInstaller, .steamClient: EmptyView()
        default: EmptyView()
        }
    }
}
'
run_audit_navguard "nav_merged_steam" "merged steam case" 1

# direct recheckCloverPit in SteamSetupView → 1
mk_repo "nav_recheck_direct"
add_file "nav_recheck_direct" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var body: some View {
        Button("Next") { Task { await coordinator.recheckCloverPit() } }
    }
}
'
run_audit_navguard "nav_recheck_direct" "direct recheckCloverPit" 1

# try? cleanup swallow → 1
mk_repo "nav_try_swallow"
add_file "nav_try_swallow" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var body: some View {
        Button("Next") { Task { try? await coordinator.stopSteamSetupSessionIfNeeded() } }
    }
}
'
run_audit_navguard "nav_try_swallow" "try? cleanup swallow" 1

# local PrefixInspector in PrefixSetupView → 1
mk_repo "nav_local_inspector"
add_file "nav_local_inspector" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixSetupView: View {
    private let prefixInspector = PrefixInspector()
}
'
run_audit_navguard "nav_local_inspector" "local prefix inspector" 1

# unstable log identity → 1
mk_repo "nav_unstable_log"
add_file "nav_unstable_log" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var logLines: [String] { [] }
    var body: some View {
        ForEach(logLines, id: \.self) { line in Text(line) }
    }
}
'
run_audit_navguard "nav_unstable_log" "unstable log identity" 1

# diagnostics footer missing → 1
mk_repo "nav_diag_footer_missing"
add_file "nav_diag_footer_missing" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var diagnosticsPageView: some View { Text("Diagnostics") }
}
'
run_audit_navguard "nav_diag_footer_missing" "diagnostics footer missing" 1

# environment completion unbound → 1
mk_repo "nav_env_unbound"
add_file "nav_env_unbound" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    func computePageCompletion() -> [String: Bool] { ["environment": prefixInspection?.isValid == true] }
}
'
run_audit_navguard "nav_env_unbound" "environment completion unbound" 1

# ── Infrastructure failure ──
# Infrastructure failure test (use fake git that exits 2)
INFRA_DIR="$FIXTURE/infra"
mkdir -p "$INFRA_DIR/Sources/MacSteam/Core"
echo "let x = true" > "$INFRA_DIR/Sources/MacSteam/Core/ProcessRunner.swift"
mkdir -p "$INFRA_DIR/fakebin"
cat > "$INFRA_DIR/fakebin/git" << 'GITEOF'
#!/bin/bash
exit 2
GITEOF
chmod +x "$INFRA_DIR/fakebin/git"
cd "$INFRA_DIR"
PATH="$INFRA_DIR/fakebin:$PATH" GIT_WORK_TREE="$INFRA_DIR" GIT_DIR="$INFRA_DIR/.git" \
  bash "$AUDIT" --cleanup-only >/dev/null 2>&1 && rc=$? || rc=$?
[ "$rc" -eq 2 ] && pass "infrastructure failure exits 2" || fail "infra failure should be exit 2, got $rc"
cd "$SCRIPT_DIR/.."

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Static audit test PASSED"
    exit 0
else
    echo "Static audit test FAILED — $FAILURES failure(s)"
    exit 1
fi
