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
    local repo="$1" label="$2" expected="$3" guardlabel="$4"
    local rc=0 out
    out=$(GIT_WORK_TREE="$FIXTURE/$repo" GIT_DIR="$FIXTURE/$repo/.git" bash "$AUDIT" --navigation-guards-only 2>&1) || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        if [ "$expected" -eq 0 ] || echo "$out" | grep -qF "$guardlabel"; then
            pass "$label"
        else
            fail "$label (expected guard '$guardlabel' in output, not found)"
        fi
    else
        fail "$label (expected exit $expected, got $rc)"
    fi
}

# Seed the required contracts (clean stubs). Each violation fixture seeds
# these first, then overwrites its target file with the violating content.
# Required-contract absence / body absence / unbalanced body → exit 2.
seed_required_files() {
    local repo="$1"
    add_file "$repo" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .installer
        case .steamClient: return .client
        default: return nil
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}

'
    add_file "$repo" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        VStack(alignment: .leading, spacing: 12) {
            canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
        }
    }
}

'
    add_file "$repo" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() {
        Task { await inspectAction.run() }
    }
}

'
    add_file "$repo" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .steamInstaller)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}

'
    add_file "$repo" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}

'
    add_file "$repo" "Sources/MacSteam/Views/CloverPitLaunchView.swift" '
struct CloverPitLaunchView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .cloverPit)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}

'
    add_file "$repo" "Sources/MacSteam/Views/CanonicalNavigationFooter.swift" '
func canonicalNavigationFooter(presentation: UltimatePagePresentation, coordinator: UltimateSetupCoordinator) -> some View {
    if presentation.hasCanonicalNavigation {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}

'
    add_file "$repo" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
    add_file "$repo" "Sources/MacSteam/Prefix/PrefixInspection.swift" '
protocol PrefixInspecting { func inspect(url: URL) -> PrefixInspection }
enum PrefixAcquisitionSource: String, Sendable {
    case existingCanonical
    case adoptedSteam
    case newlyInitialized
}
struct PrefixInspector: PrefixInspecting {
    func inspect(url: URL) -> PrefixInspection { PrefixInspection(prefixURL: url, driveCExists: true, hasWinePrefix: true, hasSteam: false, isValid: true) }
}
'
}

# clean → 0 (correct single-authority wiring, descriptor consumed, all sources)
mk_repo "nav_clean"
seed_required_files "nav_clean"
run_audit_navguard "nav_clean" "clean navigation guards" 0 ""

# required file missing → 2 (infrastructure)
mk_repo "required_file_missing"
add_file "required_file_missing" "Sources/MacSteam/Views/UltimatePageResolver.swift" 'struct UltimatePageResolver {}'
add_file "required_file_missing" "Sources/MacSteam/Views/PrefixSetupView.swift" 'struct PrefixSetupView {}'
add_file "required_file_missing" "Sources/MacSteam/Views/SteamSetupView.swift" 'struct SteamSetupView {}'
add_file "required_file_missing" "Sources/MacSteam/Views/RuntimeSetupView.swift" 'struct RuntimeSetupView {}'
add_file "required_file_missing" "Sources/MacSteam/Views/CloverPitLaunchView.swift" 'struct CloverPitLaunchView {}'
add_file "required_file_missing" "Sources/MacSteam/Views/CanonicalNavigationFooter.swift" 'func canonicalNavigationFooter() {}'
add_file "required_file_missing" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" 'final class UltimateSetupCoordinator {}'
add_file "required_file_missing" "Sources/MacSteam/Prefix/PrefixInspection.swift" 'protocol PrefixInspecting {}'
run_audit_navguard "required_file_missing" "required file missing" 2 "required contract missing"

# required function missing → 2 (infrastructure)
mk_repo "required_function_missing"
seed_required_files "required_function_missing"
add_file "required_function_missing" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .installer
        case .steamClient: return .client
        default: return nil
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
}
'
run_audit_navguard "required_function_missing" "required function missing" 2 "required contract missing"

# required body missing (progressIndicator) → 2 (infrastructure)
mk_repo "required_body_missing_progressIndicator"
seed_required_files "required_body_missing_progressIndicator"
add_file "required_body_missing_progressIndicator" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "required_body_missing_progressIndicator" "required body missing progressIndicator" 2 "required contract missing"

# root dispatch on coordinator.state → 1
mk_repo "nav_root_state"
seed_required_files "nav_root_state"
add_file "nav_root_state" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch coordinator.state { default: EmptyView() }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "nav_root_state" "root dispatch on state" 1 "root dispatch on coordinator.state in UltimateSetupView"

# merged Steam pages → 1
mk_repo "nav_merged_steam"
seed_required_files "nav_merged_steam"
add_file "nav_merged_steam" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .steamInstaller, .steamClient: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "nav_merged_steam" "merged steam case" 1 "Steam pages merged into one case in UltimateSetupView"

# direct recheckCloverPit in SteamSetupView → 1
mk_repo "nav_recheck_direct"
seed_required_files "nav_recheck_direct"
add_file "nav_recheck_direct" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .steamInstaller)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    var body: some View {
        Button("Next") { Task { await coordinator.recheckCloverPit() } }
    }
}
'
run_audit_navguard "nav_recheck_direct" "direct recheckCloverPit" 1 "SteamSetupView direct recheckCloverPit (canonical lane violation)"

# try? cleanup swallow → 1
mk_repo "nav_try_swallow"
seed_required_files "nav_try_swallow"
add_file "nav_try_swallow" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .steamInstaller)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    var body: some View {
        Button("Next") { Task { try? await coordinator.stopSteamSetupSessionIfNeeded() } }
    }
}
'
run_audit_navguard "nav_try_swallow" "try? cleanup swallow" 1 "navigation cleanup swallowed with try? in Views"

# local PrefixInspector in PrefixSetupView → 1
mk_repo "nav_local_inspector"
seed_required_files "nav_local_inspector"
add_file "nav_local_inspector" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .environment)
    private let prefixInspector = PrefixInspector()
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() { Task { await inspectAction.run() } }
}
'
run_audit_navguard "nav_local_inspector" "local prefix inspector" 1 "local PrefixInspector authority in PrefixSetupView"

# unstable log identity → 1
mk_repo "nav_unstable_log"
seed_required_files "nav_unstable_log"
add_file "nav_unstable_log" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var logLines: [String] { [] }
    var diagnosticsPageView: some View { Text("Diag") }
    var body: some View {
        ForEach(logLines, id: \.self) { line in Text(line) }
    }
}
'
run_audit_navguard "nav_unstable_log" "unstable log identity" 1 "ForEach(logLines, id: \.self) in Views (unstable log identity)"

# diagnostics footer missing → 1
mk_repo "nav_diag_footer_missing"
seed_required_files "nav_diag_footer_missing"
add_file "nav_diag_footer_missing" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View { Text("Diagnostics") }
}
'
run_audit_navguard "nav_diag_footer_missing" "diagnostics footer missing" 1 "Diagnostics page missing canonical footer in UltimateSetupView"

# environment completion unbound → 1
mk_repo "nav_env_unbound"
seed_required_files "nav_env_unbound"
add_file "nav_env_unbound" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = prefixInspection?.isValid == true
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "nav_env_unbound" "environment completion unbound" 1 "environment completion not bound to canonicalPrefixEvidenceValid"

# view writes coordinator.currentPage → 1
mk_repo "view_currentPage_write"
seed_required_files "view_currentPage_write"
add_file "view_currentPage_write" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func jump() { coordinator.currentPage = .diagnostics }
}
'
run_audit_navguard "view_currentPage_write" "view currentPage write" 1 "coordinator.currentPage write in Views"

# PrefixSetupView owns @State inspection → 1
mk_repo "prefix_state_inspection"
seed_required_files "prefix_state_inspection"
add_file "prefix_state_inspection" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    @State private var inspection: PrefixInspection?
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() { Task { await inspectAction.run() } }
}
'
run_audit_navguard "prefix_state_inspection" "prefix state inspection" 1 "@State inspection in PrefixSetupView"

# footer exists elsewhere but NOT inside diagnosticsPageView body → 1
mk_repo "footer_elsewhere_not_in_diagnostics"
seed_required_files "footer_elsewhere_not_in_diagnostics"
add_file "footer_elsewhere_not_in_diagnostics" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var body: some View {
        VStack {
            InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { _ in })
            diagnosticsPageView
        }
    }
    var diagnosticsPageView: some View { Text("Diagnostics") }
}
'
run_audit_navguard "footer_elsewhere_not_in_diagnostics" "footer elsewhere not in diagnostics" 1 "Diagnostics page missing canonical footer in UltimateSetupView"

# symbol exists elsewhere but the .environment gate is unbound → 1
mk_repo "environment_symbol_elsewhere_but_gate_unbound"
seed_required_files "environment_symbol_elsewhere_but_gate_unbound"
add_file "environment_symbol_elsewhere_but_gate_unbound" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = prefixInspection?.isValid == true
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "environment_symbol_elsewhere_but_gate_unbound" "environment symbol elsewhere but gate unbound" 1 "environment completion not bound to canonicalPrefixEvidenceValid"


# steam both modes installer → 1
mk_repo "steam_both_modes_installer"
seed_required_files "steam_both_modes_installer"
add_file "steam_both_modes_installer" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .installer
        case .steamClient: return .installer
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_both_modes_installer" "steam both modes installer" 1 "steamMode resolver case mapping invalid"

# steam resolver client maps installer → 1
mk_repo "steam_resolver_client_maps_installer"
seed_required_files "steam_resolver_client_maps_installer"
add_file "steam_resolver_client_maps_installer" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .installer
        case .steamClient: return .installer
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_resolver_client_maps_installer" "steam resolver client maps installer" 1 "steamMode resolver case mapping invalid"

# steam mapping swapped → 1
mk_repo "steam_mapping_swapped"
seed_required_files "steam_mapping_swapped"
add_file "steam_mapping_swapped" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .client
        case .steamClient: return .installer
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_mapping_swapped" "steam mapping swapped" 1 "steamMode resolver case mapping invalid"

# steam mapping duplicated → 1
mk_repo "steam_mapping_duplicated"
seed_required_files "steam_mapping_duplicated"
add_file "steam_mapping_duplicated" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .installer
        case .steamClient: return .installer
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_mapping_duplicated" "steam mapping duplicated" 1 "steamMode resolver case mapping invalid"

# steam default non-nil → 1
mk_repo "steam_default_non_nil"
seed_required_files "steam_default_non_nil"
add_file "steam_default_non_nil" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .installer
        case .steamClient: return .client
        default: return .installer
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_default_non_nil" "steam default non-nil" 1 "steamMode resolver case mapping invalid"

# steam mapping both client → 1
mk_repo "steam_mapping_both_client"
seed_required_files "steam_mapping_both_client"
add_file "steam_mapping_both_client" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: return .client
        case .steamClient: return .client
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_mapping_both_client" "steam mapping both client" 1 "steamMode resolver case mapping invalid"

# steam mapping nested return → 1
mk_repo "steam_mapping_nested_return"
seed_required_files "steam_mapping_nested_return"
add_file "steam_mapping_nested_return" "Sources/MacSteam/Views/UltimatePageResolver.swift" '
struct UltimatePageResolver {
    static func contentKind(for page: InstallerPage) -> PageContentKind { .runtime }
    static func steamMode(for page: InstallerPage) -> SteamSetupMode? {
        switch page {
        case .steamInstaller: if flag { return .installer } else { return .client }
        case .steamClient: return .client
        }
    }
    static func hasCanonicalNavigation(for page: InstallerPage) -> Bool { true }
    static func presentation(for page: InstallerPage) -> UltimatePagePresentation {
        UltimatePagePresentation(page: page, contentKind: .runtime, title: "T", stepNumber: 1, footerPage: page, steamMode: nil, hasCanonicalNavigation: true)
    }
}
'
run_audit_navguard "steam_mapping_nested_return" "steam mapping nested return" 1 "steamMode resolver case mapping invalid"

# Inspect action type present but button bypasses the lane → 1
mk_repo "prefix_inspect_action_bypasses_coordinator"
seed_required_files "prefix_inspect_action_bypasses_coordinator"
add_file "prefix_inspect_action_bypasses_coordinator" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var inspectAction: PrefixInspectAction = .production(coordinator: UltimateSetupCoordinator())
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() {
        Task { await coordinator.inspectCanonicalPrefix() }
    }
}
'
run_audit_navguard "prefix_inspect_action_bypasses_coordinator" "inspect bypasses coordinator" 1 "prefix Inspect button bypasses the production lane"

# Inspect type present but the Button path bypasses the lane → 1
mk_repo "inspect_type_present_but_button_bypasses"
seed_required_files "inspect_type_present_but_button_bypasses"
add_file "inspect_type_present_but_button_bypasses" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var inspectAction: PrefixInspectAction = .production(coordinator: UltimateSetupCoordinator())
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() {
        Task { await coordinator.inspectCanonicalPrefix() }
    }
}
'
run_audit_navguard "inspect_type_present_but_button_bypasses" "inspect type present but button bypasses" 1 "prefix Inspect button bypasses the production lane"

# button calls a DIFFERENT coordinator method directly → 1
mk_repo "button_calls_other_coordinator_method"
seed_required_files "button_calls_other_coordinator_method"
add_file "button_calls_other_coordinator_method" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var inspectAction: PrefixInspectAction = .production(coordinator: UltimateSetupCoordinator())
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() {
        Task { await coordinator.recheckCloverPit() }
    }
}
'
run_audit_navguard "button_calls_other_coordinator_method" "button calls other coordinator method" 1 "prefix Inspect button bypasses the production lane"

# PrefixInspectAction.production calls zero times → 1
mk_repo "inspect_production_calls_zero"
seed_required_files "inspect_production_calls_zero"
add_file "inspect_production_calls_zero" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { })
    }
}
struct PrefixSetupView: View {
    var inspectAction: PrefixInspectAction = .production(coordinator: UltimateSetupCoordinator())
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() {
        Task { await inspectAction.run() }
    }
}
'
run_audit_navguard "inspect_production_calls_zero" "inspect production calls zero" 1 "PrefixInspectAction.production must call inspectCanonicalPrefix exactly once"

# PrefixInspectAction.production calls twice → 1
mk_repo "inspect_production_calls_twice"
seed_required_files "inspect_production_calls_twice"
add_file "inspect_production_calls_twice" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: {
            await coordinator.inspectCanonicalPrefix()
            await coordinator.inspectCanonicalPrefix()
        })
    }
}
struct PrefixSetupView: View {
    var inspectAction: PrefixInspectAction = .production(coordinator: UltimateSetupCoordinator())
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
    func inspectPrefix() {
        Task { await inspectAction.run() }
    }
}
'
run_audit_navguard "inspect_production_calls_twice" "inspect production calls twice" 1 "PrefixInspectAction.production must call inspectCanonicalPrefix exactly once"

# canonical property always true → 1
mk_repo "canonical_property_always_true"
seed_required_files "canonical_property_always_true"
add_file "canonical_property_always_true" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool { true }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_property_always_true" "canonical property always true" 1 "canonicalPrefixEvidenceValid semantics incomplete"

# canonical property missing validity → 1
mk_repo "canonical_property_missing_validity"
seed_required_files "canonical_property_missing_validity"
add_file "canonical_property_missing_validity" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_property_missing_validity" "canonical property missing validity" 1 "canonicalPrefixEvidenceValid semantics incomplete"

# canonical property raw equality → 1
mk_repo "canonical_property_raw_equality"
seed_required_files "canonical_property_raw_equality"
add_file "canonical_property_raw_equality" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return inspection.prefixURL == layout.root
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_property_raw_equality" "canonical property raw equality" 1 "canonicalPrefixEvidenceValid terminal return mismatch"

# canonical property same-side comparison → 1
mk_repo "canonical_property_same_side_comparison"
seed_required_files "canonical_property_same_side_comparison"
add_file "canonical_property_same_side_comparison" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(layout.root) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_property_same_side_comparison" "canonical property same-side comparison" 1 "canonicalPrefixEvidenceValid terminal return mismatch"

# canonical tokens present but terminal return same-side → 1
mk_repo "canonical_tokens_present_but_terminal_return_same_side"
seed_required_files "canonical_tokens_present_but_terminal_return_same_side"
add_file "canonical_tokens_present_but_terminal_return_same_side" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        let evidence = canonicalURL(inspection.prefixURL)
        let root = canonicalURL(layout.root)
        return root == root
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_tokens_present_but_terminal_return_same_side" "canonical tokens present but terminal return same side" 1 "canonicalPrefixEvidenceValid terminal return mismatch"

# existing branch token elsewhere but skips evidence → 1
mk_repo "existing_branch_token_elsewhere_but_skips_evidence"
seed_required_files "existing_branch_token_elsewhere_but_skips_evidence"
add_file "existing_branch_token_elsewhere_but_skips_evidence" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "existing_branch_token_elsewhere_but_skips_evidence" "existing branch token elsewhere but skips evidence" 1 "prefix acquisition branch evidence ordering violation"

# adopted branch wrong source → 1
mk_repo "adopted_branch_wrong_source"
seed_required_files "adopted_branch_wrong_source"
add_file "adopted_branch_wrong_source" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .existingCanonical)
            return (adopted, .existingCanonical)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "adopted_branch_wrong_source" "adopted branch wrong source" 1 "prefix acquisition branch evidence ordering violation"

# acquisition sources swapped between branches → 1
mk_repo "acquisition_sources_swapped"
seed_required_files "acquisition_sources_swapped"
add_file "acquisition_sources_swapped" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .adoptedSteam)
            return (existing, .adoptedSteam)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .existingCanonical)
            return (adopted, .existingCanonical)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_sources_swapped" "acquisition sources swapped" 1 "prefix acquisition branch evidence ordering violation"

# existing source token only in adopted branch → 1
mk_repo "existing_source_token_only_in_adopted_branch"
seed_required_files "existing_source_token_only_in_adopted_branch"
add_file "existing_source_token_only_in_adopted_branch" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .existingCanonical)
            return (adopted, .existingCanonical)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "existing_source_token_only_in_adopted_branch" "existing source token only in adopted branch" 1 "prefix acquisition branch evidence ordering violation"

# adopted source token only in existing branch → 1
mk_repo "adopted_source_token_only_in_existing_branch"
seed_required_files "adopted_source_token_only_in_existing_branch"
add_file "adopted_source_token_only_in_existing_branch" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .adoptedSteam)
            return (existing, .adoptedSteam)
        }
        if let adopted = adoptedLayout {
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "adopted_source_token_only_in_existing_branch" "adopted source token only in existing branch" 1 "prefix acquisition branch evidence ordering violation"

# branch evidence after return → 1
mk_repo "branch_evidence_after_return"
seed_required_files "branch_evidence_after_return"
add_file "branch_evidence_after_return" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            return (existing, .existingCanonical)
            establishPrefixEvidence(for: existing, source: .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "branch_evidence_after_return" "branch evidence after return" 1 "prefix acquisition branch evidence ordering violation"

# selected layout mismatch helper argument → 1
mk_repo "selected_layout_mismatch_helper_argument"
seed_required_files "selected_layout_mismatch_helper_argument"
add_file "selected_layout_mismatch_helper_argument" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: otherLayout, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "selected_layout_mismatch_helper_argument" "selected layout mismatch helper argument" 1 "prefix acquisition branch evidence ordering violation"

# new branch evidence after return → 1
mk_repo "new_branch_evidence_after_return"
seed_required_files "new_branch_evidence_after_return"
add_file "new_branch_evidence_after_return" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        state = .prefixReady
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
    }
}
'
run_audit_navguard "new_branch_evidence_after_return" "new branch evidence after return" 1 "prefix acquisition branch evidence ordering violation"

# presentation declared but title bypasses → 1
mk_repo "presentation_declared_but_title_bypasses"
seed_required_files "presentation_declared_but_title_bypasses"
add_file "presentation_declared_but_title_bypasses" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { UltimatePageResolver.title(for: coordinator.currentPage) }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "presentation_declared_but_title_bypasses" "presentation declared but title bypasses" 1 "pageTitle must derive from presentation"

# presentation declared but step bypasses → 1
mk_repo "presentation_declared_but_step_bypasses"
seed_required_files "presentation_declared_but_step_bypasses"
add_file "presentation_declared_but_step_bypasses" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(UltimatePageResolver.stepNumber(for: coordinator.currentPage))") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "presentation_declared_but_step_bypasses" "presentation declared but step bypasses" 1 "step indicator must derive from presentation.stepNumber"

# presentation declared but content bypasses → 1
mk_repo "presentation_declared_but_content_bypasses"
seed_required_files "presentation_declared_but_content_bypasses"
add_file "presentation_declared_but_content_bypasses" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch UltimatePageResolver.contentKind(for: coordinator.currentPage) {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "presentation_declared_but_content_bypasses" "presentation declared but content bypasses" 1 "content must dispatch on presentation.contentKind"

# presentation declared but footer bypasses → 1
mk_repo "presentation_declared_but_footer_bypasses"
seed_required_files "presentation_declared_but_footer_bypasses"
add_file "presentation_declared_but_footer_bypasses" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: coordinator.currentPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}
'
run_audit_navguard "presentation_declared_but_footer_bypasses" "presentation declared but footer bypasses" 1 "footer must derive from presentation.footerPage"

# child footer hardcodes page → 1
mk_repo "child_footer_hardcodes_page"
seed_required_files "child_footer_hardcodes_page"
add_file "child_footer_hardcodes_page" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var navigationButtons: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: .environment, onNavigate: { intent in await coordinator.send(intent) })
    }
    func inspectPrefix() { Task { await inspectAction.run() } }
}
'
run_audit_navguard "child_footer_hardcodes_page" "child footer hardcodes page" 1 "footer must derive from presentation.footerPage"

# root does not consume the presentation descriptor → 1
mk_repo "presentation_not_consumed_by_root"
seed_required_files "presentation_not_consumed_by_root"
add_file "presentation_not_consumed_by_root" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: String { "not the resolver descriptor" }
    var pageTitle: String { "Step \\(presentation) — T" }
    var progressIndicator: some View {
        HStack { Text("\\(presentation)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation {
        case "x": EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
    }
}
'
run_audit_navguard "presentation_not_consumed_by_root" "presentation not consumed" 1 "presentation descriptor not consumed by root view"

# navigation capability ignored (diagnostics) → 1
mk_repo "navigation_capability_ignored"
seed_required_files "navigation_capability_ignored"
add_file "navigation_capability_ignored" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}
'
run_audit_navguard "navigation_capability_ignored" "navigation capability ignored" 1 "surface ignores navigation capability"

# runtime surface ignores capability → 1
mk_repo "runtime_navigation_capability_ignored"
seed_required_files "runtime_navigation_capability_ignored"
add_file "runtime_navigation_capability_ignored" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}
'
run_audit_navguard "runtime_navigation_capability_ignored" "runtime capability ignored" 1 "surface ignores navigation capability"

# environment surface ignores capability → 1
mk_repo "environment_navigation_capability_ignored"
seed_required_files "environment_navigation_capability_ignored"
add_file "environment_navigation_capability_ignored" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var navigationButtons: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
    func inspectPrefix() { Task { await inspectAction.run() } }
}
'
run_audit_navguard "environment_navigation_capability_ignored" "environment capability ignored" 1 "surface ignores navigation capability"

# steam surface ignores capability → 1
mk_repo "steam_navigation_capability_ignored"
seed_required_files "steam_navigation_capability_ignored"
add_file "steam_navigation_capability_ignored" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .steamInstaller)
    var navigationButtons: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}
'
run_audit_navguard "steam_navigation_capability_ignored" "steam capability ignored" 1 "surface ignores navigation capability"

# cloverpit surface ignores capability → 1
mk_repo "cloverpit_navigation_capability_ignored"
seed_required_files "cloverpit_navigation_capability_ignored"
add_file "cloverpit_navigation_capability_ignored" "Sources/MacSteam/Views/CloverPitLaunchView.swift" '
struct CloverPitLaunchView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .cloverPit)
    var navigationButtons: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}
'
run_audit_navguard "cloverpit_navigation_capability_ignored" "cloverpit capability ignored" 1 "surface ignores navigation capability"

# diagnostics surface ignores capability → 1
mk_repo "diagnostics_navigation_capability_ignored"
seed_required_files "diagnostics_navigation_capability_ignored"
add_file "diagnostics_navigation_capability_ignored" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
    }
}
'
run_audit_navguard "diagnostics_navigation_capability_ignored" "diagnostics capability ignored" 1 "surface ignores navigation capability"

# shared footer helper ignores capability → 1
mk_repo "shared_footer_helper_ignores_capability"
seed_required_files "shared_footer_helper_ignores_capability"
add_file "shared_footer_helper_ignores_capability" "Sources/MacSteam/Views/CanonicalNavigationFooter.swift" '
func canonicalNavigationFooter(presentation: UltimatePagePresentation, coordinator: UltimateSetupCoordinator) -> some View {
    InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
}
'
run_audit_navguard "shared_footer_helper_ignores_capability" "shared footer helper ignores capability" 1 "shared footer helper ignores navigation capability"

# ── U1R17-G recurrence-gate fixtures ──

# FIX 1: canonical success return with trailing || true → 1
mk_repo "canonical_success_return_or_true"
seed_required_files "canonical_success_return_or_true"
add_file "canonical_success_return_or_true" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root) || true
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_success_return_or_true" "canonical success return or true" 1 "canonicalPrefixEvidenceValid terminal return mismatch"

# FIX 1: correct expression unused, then return true → 1
mk_repo "canonical_correct_expression_unused_then_return_true"
seed_required_files "canonical_correct_expression_unused_then_return_true"
add_file "canonical_correct_expression_unused_then_return_true" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        let marker = canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
        return true
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_correct_expression_unused_then_return_true" "canonical correct expression unused then return true" 1 "canonicalPrefixEvidenceValid terminal return mismatch"

# FIX 1: canonical success return wrapped in ternary → 1
mk_repo "canonical_success_return_ternary"
seed_required_files "canonical_success_return_ternary"
add_file "canonical_success_return_ternary" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return condition
            ? canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
            : true
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_success_return_ternary" "canonical success return ternary" 1 "canonicalPrefixEvidenceValid terminal return mismatch"

# FIX 1: canonicalURL correct expression unused, then return url → 1
mk_repo "canonical_url_correct_expression_unused_then_return_url"
seed_required_files "canonical_url_correct_expression_unused_then_return_url"
add_file "canonical_url_correct_expression_unused_then_return_url" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        _ = url.standardizedFileURL.resolvingSymlinksInPath()
        return url
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_url_correct_expression_unused_then_return_url" "canonical url correct expression unused then return url" 1 "canonicalURL terminal return mismatch"

# FIX 1: canonicalURL return with fallback (?? url) → 1
mk_repo "canonical_url_return_has_fallback"
seed_required_files "canonical_url_return_has_fallback"
add_file "canonical_url_return_has_fallback" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        return url.standardizedFileURL.resolvingSymlinksInPath() ?? url
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_url_return_has_fallback" "canonical url return has fallback" 1 "canonicalURL terminal return mismatch"

# FIX 2: expected source only in a comment → 1
mk_repo "acquisition_expected_source_only_in_comment"
seed_required_files "acquisition_expected_source_only_in_comment"
add_file "acquisition_expected_source_only_in_comment" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            // source: .existingCanonical
            establishPrefixEvidence(for: existing, source: .adoptedSteam)
            return (existing, .adoptedSteam)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_expected_source_only_in_comment" "acquisition expected source only in comment" 1 "prefix acquisition branch evidence ordering violation"

# FIX 2: expected source only in an unrelated call → 1
mk_repo "acquisition_expected_source_in_unrelated_call"
seed_required_files "acquisition_expected_source_in_unrelated_call"
add_file "acquisition_expected_source_in_unrelated_call" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            _ = auditMarker(source: .existingCanonical)
            establishPrefixEvidence(for: existing, source: .adoptedSteam)
            return (existing, .adoptedSteam)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_expected_source_in_unrelated_call" "acquisition expected source in unrelated call" 1 "prefix acquisition branch evidence ordering violation"

# FIX 2: wrong source in the same evidence call → 1
mk_repo "acquisition_wrong_source_same_call"
seed_required_files "acquisition_wrong_source_same_call"
add_file "acquisition_wrong_source_same_call" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .existingCanonical)
            return (adopted, .existingCanonical)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_wrong_source_same_call" "acquisition wrong source same call" 1 "prefix acquisition branch evidence ordering violation"

# FIX 2: dynamic source in the same evidence call → 1
mk_repo "acquisition_dynamic_source_same_call"
seed_required_files "acquisition_dynamic_source_same_call"
add_file "acquisition_dynamic_source_same_call" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: dynamicSource)
            return (existing, dynamicSource)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_dynamic_source_same_call" "acquisition dynamic source same call" 1 "prefix acquisition branch evidence ordering violation"

# FIX 2: newlyInitialized source token outside the evidence call → 1
mk_repo "newly_initialized_source_token_outside_evidence_call"
seed_required_files "newly_initialized_source_token_outside_evidence_call"
add_file "newly_initialized_source_token_outside_evidence_call" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = marker(source: .newlyInitialized)
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .adoptedSteam)
        state = .prefixReady
    }
}
'
run_audit_navguard "newly_initialized_source_token_outside_evidence_call" "newly initialized source token outside evidence call" 1 "prefix acquisition branch evidence ordering violation"

# FIX 3: runtime footer uses hardcoded presentation → 1
mk_repo "runtime_footer_uses_hardcoded_presentation"
seed_required_files "runtime_footer_uses_hardcoded_presentation"
add_file "runtime_footer_uses_hardcoded_presentation" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: UltimatePageResolver.presentation(for: .runtime), coordinator: coordinator)
    }
}
'
run_audit_navguard "runtime_footer_uses_hardcoded_presentation" "runtime footer uses hardcoded presentation" 1 "surface canonical footer argument mismatch"

# FIX 3: environment footer uses other presentation → 1
mk_repo "environment_footer_uses_other_presentation"
seed_required_files "environment_footer_uses_other_presentation"
add_file "environment_footer_uses_other_presentation" "Sources/MacSteam/Views/PrefixSetupView.swift" '
struct PrefixInspectAction {
    let run: () async -> Void
    static func production(coordinator: UltimateSetupCoordinator) -> PrefixInspectAction {
        PrefixInspectAction(run: { await coordinator.inspectCanonicalPrefix() })
    }
}
struct PrefixSetupView: View {
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: otherPresentation, coordinator: coordinator)
    }
    func inspectPrefix() { Task { await inspectAction.run() } }
}
'
run_audit_navguard "environment_footer_uses_other_presentation" "environment footer uses other presentation" 1 "surface canonical footer argument mismatch"

# FIX 3: steam installer footer uses client presentation → 1
mk_repo "steam_installer_footer_uses_client_presentation"
seed_required_files "steam_installer_footer_uses_client_presentation"
add_file "steam_installer_footer_uses_client_presentation" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .steamInstaller)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: UltimatePageResolver.presentation(for: .steamClient), coordinator: coordinator)
    }
}
'
run_audit_navguard "steam_installer_footer_uses_client_presentation" "steam installer footer uses client presentation" 1 "surface canonical footer argument mismatch"

# FIX 3: steam client footer uses installer presentation → 1
mk_repo "steam_client_footer_uses_installer_presentation"
seed_required_files "steam_client_footer_uses_installer_presentation"
add_file "steam_client_footer_uses_installer_presentation" "Sources/MacSteam/Views/SteamSetupView.swift" '
struct SteamSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .steamClient)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: UltimatePageResolver.presentation(for: .steamInstaller), coordinator: coordinator)
    }
}
'
run_audit_navguard "steam_client_footer_uses_installer_presentation" "steam client footer uses installer presentation" 1 "surface canonical footer argument mismatch"

# FIX 3: cloverpit footer uses other coordinator → 1
mk_repo "cloverpit_footer_uses_other_coordinator"
seed_required_files "cloverpit_footer_uses_other_coordinator"
add_file "cloverpit_footer_uses_other_coordinator" "Sources/MacSteam/Views/CloverPitLaunchView.swift" '
struct CloverPitLaunchView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .cloverPit)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: otherCoordinator)
    }
}
'
run_audit_navguard "cloverpit_footer_uses_other_coordinator" "cloverpit footer uses other coordinator" 1 "surface canonical footer argument mismatch"

# FIX 3: diagnostics footer uses hardcoded runtime presentation → 1
mk_repo "diagnostics_footer_uses_hardcoded_runtime_presentation"
seed_required_files "diagnostics_footer_uses_hardcoded_runtime_presentation"
add_file "diagnostics_footer_uses_hardcoded_runtime_presentation" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        canonicalNavigationFooter(presentation: UltimatePageResolver.presentation(for: .runtime), coordinator: coordinator)
    }
}
'
run_audit_navguard "diagnostics_footer_uses_hardcoded_runtime_presentation" "diagnostics footer uses hardcoded runtime presentation" 1 "surface canonical footer argument mismatch"

# FIX 3: correct helper call dead but wrong call rendered → 1
mk_repo "correct_helper_call_dead_but_wrong_call_rendered"
seed_required_files "correct_helper_call_dead_but_wrong_call_rendered"
add_file "correct_helper_call_dead_but_wrong_call_rendered" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        VStack {
            InstallerNavigationFooter(validator: DefaultInstallerNavigationValidator(), currentPage: presentation.footerPage, onNavigate: { intent in await coordinator.send(intent) })
            canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
        }
    }
}
'
run_audit_navguard "correct_helper_call_dead_but_wrong_call_rendered" "correct helper call dead but wrong call rendered" 1 "surface ignores navigation capability"

# ── U1R17-H control-flow dominance fixtures ──

# H1: nested early return in canonicalPrefixEvidenceValid → 1
mk_repo "canonical_nested_early_true"
seed_required_files "canonical_nested_early_true"
add_file "canonical_nested_early_true" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        if inspection.hasSteam { return true }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_nested_early_true" "canonical nested early true" 1 "canonicalPrefixEvidenceValid control-flow dominance violation"

# H1: nested raw return in canonicalURL → 1
mk_repo "canonical_url_nested_raw_return"
seed_required_files "canonical_url_nested_raw_return"
add_file "canonical_url_nested_raw_return" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        if url.isFileURL { return url }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "canonical_url_nested_raw_return" "canonical url nested raw return" 1 "canonicalURL control-flow dominance violation"

# H2: correct call inside an uninvoked closure → 1
mk_repo "acquisition_correct_call_in_uninvoked_closure"
seed_required_files "acquisition_correct_call_in_uninvoked_closure"
add_file "acquisition_correct_call_in_uninvoked_closure" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let work = { establishPrefixEvidence(for: existing, source: .existingCanonical) }
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_correct_call_in_uninvoked_closure" "acquisition correct call in uninvoked closure" 1 "prefix acquisition evidence control-flow dominance violation"

# H2: correct call inside a false branch → 1
mk_repo "acquisition_correct_call_in_false_branch"
seed_required_files "acquisition_correct_call_in_false_branch"
add_file "acquisition_correct_call_in_false_branch" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            if false { establishPrefixEvidence(for: existing, source: .existingCanonical) }
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        _ = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil)
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}
'
run_audit_navguard "acquisition_correct_call_in_false_branch" "acquisition correct call in false branch" 1 "prefix acquisition evidence control-flow dominance violation"

# H2: newlyInitialized call in a false branch → 1
mk_repo "newly_initialized_call_in_false_branch"
seed_required_files "newly_initialized_call_in_false_branch"
add_file "newly_initialized_call_in_false_branch" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if false { establishPrefixEvidence(for: layout, source: .newlyInitialized) }
        state = .prefixReady
    }
}
'
run_audit_navguard "newly_initialized_call_in_false_branch" "newly initialized call in false branch" 1 "prefix acquisition evidence control-flow dominance violation"

# H3: correct helper only inside a false branch → 1
mk_repo "surface_correct_helper_only_in_false_branch"
seed_required_files "surface_correct_helper_only_in_false_branch"
add_file "surface_correct_helper_only_in_false_branch" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        if false { canonicalNavigationFooter(presentation: presentation, coordinator: coordinator) }
    }
}
'
run_audit_navguard "surface_correct_helper_only_in_false_branch" "surface correct helper only in false branch" 1 "surface canonical footer render-path violation"

# H3: correct helper only inside an uninvoked closure → 1
mk_repo "surface_correct_helper_only_in_uninvoked_closure"
seed_required_files "surface_correct_helper_only_in_uninvoked_closure"
add_file "surface_correct_helper_only_in_uninvoked_closure" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        let f = { canonicalNavigationFooter(presentation: presentation, coordinator: coordinator) }
    }
}
'
run_audit_navguard "surface_correct_helper_only_in_uninvoked_closure" "surface correct helper only in uninvoked closure" 1 "surface canonical footer render-path violation"

# H3: diagnostics helper nested inside ScrollView → 1
mk_repo "diagnostics_helper_nested_in_scrollview"
seed_required_files "diagnostics_helper_nested_in_scrollview"
add_file "diagnostics_helper_nested_in_scrollview" "Sources/MacSteam/Views/UltimateSetupView.swift" '
struct UltimateSetupView: View {
    var presentation: UltimatePagePresentation { UltimatePageResolver.presentation(for: .runtime) }
    var pageTitle: String { "Step \(presentation.stepNumber) — \(presentation.title)" }
    var progressIndicator: some View {
        HStack { Text("\(presentation.stepNumber)") }
    }
    @ViewBuilder
    var content: some View {
        switch presentation.contentKind {
        case .runtime: EmptyView()
        default: EmptyView()
        }
    }
    var diagnosticsPageView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
            }
        }
    }
}
'
run_audit_navguard "diagnostics_helper_nested_in_scrollview" "diagnostics helper nested in scrollview" 1 "surface canonical footer render-path violation"

# H3: helper assigned to an unused let → 1
mk_repo "surface_helper_assigned_to_unused_let"
seed_required_files "surface_helper_assigned_to_unused_let"
add_file "surface_helper_assigned_to_unused_let" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        let footer = canonicalNavigationFooter(presentation: presentation, coordinator: coordinator)
        return footer
    }
}
'
run_audit_navguard "surface_helper_assigned_to_unused_let" "surface helper assigned to unused let" 1 "surface canonical footer render-path violation"

# H3: unbalanced parens in the helper call → 2 (infrastructure)
mk_repo "surface_helper_call_unbalanced_parens"
seed_required_files "surface_helper_call_unbalanced_parens"
add_file "surface_helper_call_unbalanced_parens" "Sources/MacSteam/Views/RuntimeSetupView.swift" '
struct RuntimeSetupView: View {
    var presentation: UltimatePagePresentation = UltimatePageResolver.presentation(for: .runtime)
    var navigationButtons: some View {
        canonicalNavigationFooter(presentation: presentation, coordinator: coordinator
    }
}
'
run_audit_navguard "surface_helper_call_unbalanced_parens" "surface helper call unbalanced parens" 2 "required contract unparseable"

# ── U1R17-I branch inventory fixtures ──

mk_repo "existing_acquisition_branch_missing"
seed_required_files "existing_acquisition_branch_missing"
add_file "existing_acquisition_branch_missing" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "existing_acquisition_branch_missing" "existing acquisition branch missing" 1 "prefix acquisition branch inventory violation"

mk_repo "adopted_acquisition_branch_missing"
seed_required_files "adopted_acquisition_branch_missing"
add_file "adopted_acquisition_branch_missing" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "adopted_acquisition_branch_missing" "adopted acquisition branch missing" 1 "prefix acquisition branch inventory violation"

mk_repo "both_acquisition_branches_missing"
seed_required_files "both_acquisition_branches_missing"
add_file "both_acquisition_branches_missing" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "both_acquisition_branches_missing" "both acquisition branches missing" 1 "prefix acquisition branch inventory violation"

mk_repo "existing_acquisition_branch_duplicated"
seed_required_files "existing_acquisition_branch_duplicated"
add_file "existing_acquisition_branch_duplicated" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let existing2 = validatedLayout {
            establishPrefixEvidence(for: existing2, source: .existingCanonical)
            return (existing2, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "existing_acquisition_branch_duplicated" "existing acquisition branch duplicated" 1 "prefix acquisition branch inventory violation"

mk_repo "adopted_acquisition_branch_duplicated"
seed_required_files "adopted_acquisition_branch_duplicated"
add_file "adopted_acquisition_branch_duplicated" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        if let adopted2 = adoptedLayout {
            establishPrefixEvidence(for: adopted2, source: .adoptedSteam)
            return (adopted2, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "adopted_acquisition_branch_duplicated" "adopted acquisition branch duplicated" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_tokens_only_in_closure"
seed_required_files "acquisition_branch_tokens_only_in_closure"
add_file "acquisition_branch_tokens_only_in_closure" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        let f = {
            if let existing = validatedLayout {
                establishPrefixEvidence(for: existing, source: .existingCanonical)
                return (existing, .existingCanonical)
            }
            if let adopted = adoptedLayout {
                establishPrefixEvidence(for: adopted, source: .adoptedSteam)
                return (adopted, .adoptedSteam)
            }
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_tokens_only_in_closure" "acquisition branch tokens only in closure" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_order_swapped"
seed_required_files "acquisition_branch_order_swapped"
add_file "acquisition_branch_order_swapped" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_order_swapped" "acquisition branch order swapped" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_terminal_nil_before_branches"
seed_required_files "acquisition_terminal_nil_before_branches"
add_file "acquisition_terminal_nil_before_branches" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        return nil
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_terminal_nil_before_branches" "acquisition terminal nil before branches" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_terminal_nil_duplicated"
seed_required_files "acquisition_terminal_nil_duplicated"
add_file "acquisition_terminal_nil_duplicated" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_terminal_nil_duplicated" "acquisition terminal nil duplicated" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_terminal_fallback_non_nil"
seed_required_files "acquisition_terminal_fallback_non_nil"
add_file "acquisition_terminal_fallback_non_nil" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return (existing, .existingCanonical)
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_terminal_fallback_non_nil" "acquisition terminal fallback non nil" 1 "prefix acquisition branch inventory violation"

# ── U1R17-J executable-shape fixtures ──

mk_repo "acquisition_validated_branch_extra_false_predicate"
seed_required_files "acquisition_validated_branch_extra_false_predicate"
add_file "acquisition_validated_branch_extra_false_predicate" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout, false {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_validated_branch_extra_false_predicate" "validated branch extra false predicate" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_adopted_branch_extra_false_predicate"
seed_required_files "acquisition_adopted_branch_extra_false_predicate"
add_file "acquisition_adopted_branch_extra_false_predicate" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout, false {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_adopted_branch_extra_false_predicate" "adopted branch extra false predicate" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_router_early_bypass_before_branches"
seed_required_files "acquisition_router_early_bypass_before_branches"
add_file "acquisition_router_early_bypass_before_branches" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if bypass {
            return nil
        }
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_router_early_bypass_before_branches" "router early bypass before branches" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_router_extra_direct_statement"
seed_required_files "acquisition_router_extra_direct_statement"
add_file "acquisition_router_extra_direct_statement" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        let x = computeSomething()
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_router_extra_direct_statement" "router extra direct statement" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_nested_exit_after_evidence"
seed_required_files "acquisition_branch_nested_exit_after_evidence"
add_file "acquisition_branch_nested_exit_after_evidence" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            if bypass {
                return nil
            }
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_nested_exit_after_evidence" "branch nested exit after evidence" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_extra_statement_after_evidence"
seed_required_files "acquisition_branch_extra_statement_after_evidence"
add_file "acquisition_branch_extra_statement_after_evidence" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            let x = computeSomething()
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_extra_statement_after_evidence" "branch extra statement after evidence" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_terminal_nil_coalescing"
seed_required_files "acquisition_terminal_nil_coalescing"
add_file "acquisition_terminal_nil_coalescing" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil ?? fallbackAcquisition
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_terminal_nil_coalescing" "terminal nil coalescing" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_terminal_nil_ternary"
seed_required_files "acquisition_terminal_nil_ternary"
add_file "acquisition_terminal_nil_ternary" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            return (adopted, .adoptedSteam)
        }
        return nil ? valueA : valueB
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_terminal_nil_ternary" "terminal nil ternary" 1 "prefix acquisition branch inventory violation"

# ── U1R17-K branch-log executable-shape fixtures ──

mk_repo "acquisition_branch_log_closure_control_flow"
seed_required_files "acquisition_branch_log_closure_control_flow"
add_file "acquisition_branch_log_closure_control_flow" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("valid=\({
                if bypass {
                    fatalError("blocked")
                }
                return evidence.isValid
            }())")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_closure_control_flow" "log closure control flow" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_side_effect_call"
seed_required_files "acquisition_branch_log_side_effect_call"
add_file "acquisition_branch_log_side_effect_call" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("valid=\(sideEffect())")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_side_effect_call" "log side effect call" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_executable_interpolation"
seed_required_files "acquisition_branch_log_executable_interpolation"
add_file "acquisition_branch_log_executable_interpolation" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("valid=\(evidence.isValid || bypass)")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_executable_interpolation" "log executable interpolation" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_adopted_branch_log_executable_interpolation"
seed_required_files "acquisition_adopted_branch_log_executable_interpolation"
add_file "acquisition_adopted_branch_log_executable_interpolation" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("valid=\(evidence.isValid ? true : fatalError())")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_adopted_branch_log_executable_interpolation" "adopted log executable interpolation" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_second_interpolation"
seed_required_files "acquisition_branch_log_second_interpolation"
add_file "acquisition_branch_log_second_interpolation" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("valid=\(evidence.isValid) extra=\(sideEffect())")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_second_interpolation" "log second interpolation" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_trailing_statement"
seed_required_files "acquisition_branch_log_trailing_statement"
add_file "acquisition_branch_log_trailing_statement" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))") && sideEffect()
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_trailing_statement" "log trailing statement" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_wrong_evidence_variable"
seed_required_files "acquisition_branch_log_wrong_evidence_variable"
add_file "acquisition_branch_log_wrong_evidence_variable" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("valid=\(other.isValid)")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_wrong_evidence_variable" "log wrong evidence variable" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_wrong_literal"
seed_required_files "acquisition_branch_log_wrong_literal"
add_file "acquisition_branch_log_wrong_literal" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Wrong literal text (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_wrong_literal" "log wrong literal" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_adopted_branch_log_validated_literal"
seed_required_files "acquisition_adopted_branch_log_validated_literal"
add_file "acquisition_adopted_branch_log_validated_literal" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_adopted_branch_log_validated_literal" "adopted log validated literal" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_unbound_evidence_call"
seed_required_files "acquisition_branch_unbound_evidence_call"
add_file "acquisition_branch_unbound_evidence_call" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_unbound_evidence_call" "unbound evidence call" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_evidence_wrong_binding_name"
seed_required_files "acquisition_branch_evidence_wrong_binding_name"
add_file "acquisition_branch_evidence_wrong_binding_name" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let ev = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_evidence_wrong_binding_name" "evidence wrong binding name" 1 "prefix acquisition branch inventory violation"

# ── U1R17-L source-span binding fixtures ──

mk_repo "acquisition_branch_log_canonical_line_comment_decoy"
seed_required_files "acquisition_branch_log_canonical_line_comment_decoy"
add_file "acquisition_branch_log_canonical_line_comment_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            // log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            log(sideEffect())
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_canonical_line_comment_decoy" "validated line comment decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_adopted_branch_log_canonical_line_comment_decoy"
seed_required_files "acquisition_adopted_branch_log_canonical_line_comment_decoy"
add_file "acquisition_adopted_branch_log_canonical_line_comment_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            // log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            log(sideEffect())
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_adopted_branch_log_canonical_line_comment_decoy" "adopted line comment decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_canonical_block_comment_decoy"
seed_required_files "acquisition_branch_log_canonical_block_comment_decoy"
add_file "acquisition_branch_log_canonical_block_comment_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            /* log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))") */
            log("wrong text")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_canonical_block_comment_decoy" "block comment decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_canonical_string_decoy"
seed_required_files "acquisition_branch_log_canonical_string_decoy"
add_file "acquisition_branch_log_canonical_string_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("see: Canonical prefix resolved (evidence isValid=\(evidence.isValid) end")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_canonical_string_decoy" "string decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_decoy_outside_branch"
seed_required_files "acquisition_branch_log_decoy_outside_branch"
add_file "acquisition_branch_log_decoy_outside_branch" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("wrong")
            return (existing, .existingCanonical)
        }
        // log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_decoy_outside_branch" "decoy outside branch" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_decoy_in_other_branch"
seed_required_files "acquisition_branch_log_decoy_in_other_branch"
add_file "acquisition_branch_log_decoy_in_other_branch" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("wrong")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            // log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_decoy_in_other_branch" "decoy in other branch" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_multiline_string_decoy"
seed_required_files "acquisition_branch_log_multiline_string_decoy"
add_file "acquisition_branch_log_multiline_string_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log("""Canonical prefix resolved (evidence isValid=\(evidence.isValid))""")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_multiline_string_decoy" "multiline string decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_raw_string_decoy"
seed_required_files "acquisition_branch_log_raw_string_decoy"
add_file "acquisition_branch_log_raw_string_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            log(#"Canonical prefix resolved (evidence isValid=\(evidence.isValid))"#)
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_raw_string_decoy" "raw string decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_nested_block_comment_decoy"
seed_required_files "acquisition_branch_log_nested_block_comment_decoy"
add_file "acquisition_branch_log_nested_block_comment_decoy" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            /* /* log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))") */ */
            log("wrong")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_nested_block_comment_decoy" "nested block comment decoy" 1 "prefix acquisition branch inventory violation"

mk_repo "acquisition_branch_log_unterminated_block_comment"
seed_required_files "acquisition_branch_log_unterminated_block_comment"
add_file "acquisition_branch_log_unterminated_block_comment" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {
        if let existing = validatedLayout {
            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)
            /* log("Canonical prefix resolved (evidence isValid=\(evidence.isValid))")
            log("wrong")
            return (existing, .existingCanonical)
        }
        if let adopted = adoptedLayout {
            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)
            log("Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))")
            return (adopted, .adoptedSteam)
        }
        return nil
    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_unterminated_block_comment" "unterminated block comment" 2 "required contract unparseable"

mk_repo "acquisition_branch_log_positive_whitespace"
seed_required_files "acquisition_branch_log_positive_whitespace"
add_file "acquisition_branch_log_positive_whitespace" "Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift" '
final class UltimateSetupCoordinator {
    var canonicalPrefixEvidenceValid: Bool {
        guard let layout = prefixLayout, let inspection = prefixInspection, inspection.isValid else { return false }
        return canonicalURL(inspection.prefixURL) == canonicalURL(layout.root)
    }
    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
    func establishPrefixEvidence(for layout: PrefixLayout, source: PrefixAcquisitionSource) { }
    func establishExistingPrefixAcquisition(validatedLayout: PrefixLayout?, adoptedLayout: PrefixLayout?) -> (PrefixLayout, PrefixAcquisitionSource)? {

        if let existing = validatedLayout {

            let evidence = establishPrefixEvidence(for: existing, source: .existingCanonical)

            log(  "Canonical prefix resolved (evidence isValid=\(evidence.isValid))"  )

            return (existing, .existingCanonical)

        }

        if let adopted = adoptedLayout {

            let evidence = establishPrefixEvidence(for: adopted, source: .adoptedSteam)

            log(  "Adopted existing Steam prefix (evidence isValid=\(evidence.isValid))"  )

            return (adopted, .adoptedSteam)

        }

        return nil

    }
    func computePageCompletion() -> [String: Bool] {
        var completion: [String: Bool] = [:]
        completion[.environment] = canonicalPrefixEvidenceValid
        return completion
    }
    func createPrefix() {
        if let acquisition = establishExistingPrefixAcquisition(validatedLayout: nil, adoptedLayout: nil) {
            if acquisition.layout.signature().steamExePresent { state = .steamReady }
        }
        establishPrefixEvidence(for: layout, source: .newlyInitialized)
        state = .prefixReady
    }
}

'
run_audit_navguard "acquisition_branch_log_positive_whitespace" "positive whitespace" 0 ""



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
