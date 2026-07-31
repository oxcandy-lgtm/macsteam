#!/bin/bash
# U1R16-R1F29 Static Audit — fail-closed git grep + optional scope
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Allow GIT_WORK_TREE to override the repo root (for fixture testing)
REPO_ROOT="${GIT_WORK_TREE:-$DIR}"
cd "$REPO_ROOT" || exit 2

PROCESS_RUNNER_ONLY=0
CLEANUP_ONLY=0
ULTIMATE_LIFECYCLE_ONLY=0
DIAGNOSTIC_LOG_REDACTION_ONLY=0
for arg in "$@"; do
    [ "$arg" = "--process-runner-only" ] && PROCESS_RUNNER_ONLY=1
    [ "$arg" = "--cleanup-only" ] && CLEANUP_ONLY=1
    [ "$arg" = "--ultimate-lifecycle-only" ] && ULTIMATE_LIFECYCLE_ONLY=1
    [ "$arg" = "--diagnostic-log-redaction-only" ] && DIAGNOSTIC_LOG_REDACTION_ONLY=1
done

VIOLATIONS=0

check() {
    local label="$1" pattern="$2"
    shift 2

    local tmpout
    tmpout=$(mktemp /tmp/u1r16-audit.XXXXXX)

    set +e
    git grep -n -E -- "$pattern" -- "$@" >"$tmpout" 2>&1
    local status=$?
    set -e

    case "$status" in
        0)
            local count
            count=$(wc -l <"$tmpout")
            echo "❌ $label — $count found:" >&2
            cat "$tmpout" >&2
            VIOLATIONS=$((VIOLATIONS + count))
            ;;
        1) echo "✅ $label — 0" >&2 ;;
        *)
            echo "ERROR: audit infrastructure failure: $label" >&2
            cat "$tmpout" >&2
            exit 2
            ;;
    esac

    rm -f "$tmpout"
}

# ── ProcessRunner production guards (zero tolerance) ──
check "readToEnd" 'readToEnd\(' \
    Sources/MacSteam/Core/ProcessRunner.swift \
    Sources/MacSteam/Core/BoundedPipeCapture.swift

check "waitUntilExit" 'waitUntilExit\(' \
    Sources/MacSteam/Core

check "ThreadSafeData" 'ThreadSafeData' \
    Sources/MacSteam/Core

check "direct kill" '(^|[^[:alnum:]_])kill\(' \
    Sources/MacSteam/Core/ProcessRunner.swift

check "zero identity fallback" 'startTimeSeconds:[[:space:]]*0' \
    Sources/MacSteam/Core/ProcessRunner.swift

check "optional identity lookup" 'try\?[[:space:]]+identityProvider' \
    Sources/MacSteam/Core/ProcessRunner.swift

check "optional termination wait" 'try\?[[:space:]]+await[[:space:]]+termCtrl\.wait' \
    Sources/MacSteam/Core/ProcessRunner.swift

if [ "$PROCESS_RUNNER_ONLY" -eq 1 ]; then
    if [ "$VIOLATIONS" -eq 0 ]; then
        echo "✅ ProcessRunner audit PASSED — 0 violations" >&2
        exit 0
    else
        echo "💥 ProcessRunner audit FAILED — $VIOLATIONS violation(s)" >&2
        exit 1
    fi
fi

if [ "$CLEANUP_ONLY" -eq 1 ]; then
    # ProcessRunner scope — no restrictions
    # Cleanup scope checks:
    check "try? in InstallerSupervisor" 'try\?[[:space:]]' Sources/MacSteam/Installer/InstallerSupervisor.swift
    check "try? in PrefixProcessTerminator" 'try\?[[:space:]]' Sources/MacSteam/Processes/PrefixProcessTerminator.swift
    check "no-handle early return in stopAndClean" 'guard activeHandle else' Sources/MacSteam/Installer/InstallerSupervisor.swift
    check "concrete ProcessSupervisor" 'processSupervisor: ProcessSupervisor([^)]|$)' Sources/MacSteam/Installer/InstallerSupervisor.swift
    check "clock-based deadline in pollForExit" 'ContinuousClock.now' Sources/MacSteam/Processes/PrefixProcessTerminator.swift
    check "op[.]phase direct assignment" 'op\.phase[[:space:]]*=' Sources/MacSteam/Installer/InstallerSupervisor.swift

    # ProcessRunner direct use in PrefixProcessTerminator
    check "direct ProcessRunner in PrefixProcessTerminator" 'ProcessRunner[[:space:]]*\(' Sources/MacSteam/Processes/PrefixProcessTerminator.swift

    # wineserverProbe must not return !output.isEmpty without exitCode check
    # Use Python scanner for multi-line check (fail-closed)
    python3 -c "
import sys, re
with open('Sources/MacSteam/Processes/WineControlLane.swift') as f:
    content = f.read()
# Find wineserverProbe function body
m = re.search(r'func wineserverProbe\(.*?\{', content)
if not m:
    sys.exit(1)
start = m.end()
depth = 1; i = start
while depth > 0 and i < len(content):
    if content[i] == '{': depth += 1
    elif content[i] == '}': depth -= 1
    i += 1
body = content[start:i-1]
if 'guard result.exitCode' in body:
    sys.exit(0)
else:
    sys.exit(1)
"; rc=$?; case $rc in
    0) ;;
    1) echo "❌ wineserverProbe exitCode guard — 1 found"; VIOLATIONS=$((VIOLATIONS + 1)) ;;
    *) echo "ERROR: wineserverProbe scanner infrastructure failure"; exit 2 ;;
esac

    check "empty catch block in InstallerSupervisor" 'catch[[:space:]]*\{[[:space:]]*\}' Sources/MacSteam/Installer/InstallerSupervisor.swift

    if [ "$VIOLATIONS" -eq 0 ]; then
        echo "✅ Cleanup audit PASSED — 0 violations"
        exit 0
    else
        echo "❌ Cleanup audit — $VIOLATIONS violation(s)"
        exit 1
    fi
fi

# ── Ultimate lifecycle only ──
if [ "$ULTIMATE_LIFECYCLE_ONLY" -eq 1 ]; then
    # ProcessRunner scope — no restrictions
    # Cleanup scope — no restrictions
    # Ultimate lifecycle scope checks:
    check_mode_detached() { git grep -n -E 'mode:[[:space:]]*\.detached' -- "$@" 2>/dev/null; }
    check_mode_detached Sources/MacSteam/Ultimate/ && echo "❌ detached Steam launch — 1 found" && VIOLATIONS=$((VIOLATIONS + 1)) || true
    check_mode_detached Sources/MacSteam/Installer/ && echo "❌ detached installer — 1 found" && VIOLATIONS=$((VIOLATIONS + 1)) || true

    check "try? installer stop" 'try\?.*installer.*stop' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift
    check "try? session stop" 'try\?.*session.*stop' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift
    check "try? prefix cleanup" 'try\?[[:space:]]*await.*prefix.*clean' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift
    check "direct wineControl.taskList in stopAll" 'wineControl\.taskList' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift
    check "PID in cleanup reason" '\[PID' Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift
    # Verify GameSessionSupervisor has mode validation (invert check: 1=clean, 0=violation)
    if git -C "$REPO_ROOT" grep -q -E 'validateSessionPlan' -- Sources/MacSteam/Sessions/GameSessionSupervisor.swift 2>/dev/null; then
        : # validation present — clean
    else
        echo "❌ session launch without supervisedSession — 1 found"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi

    if [ "$VIOLATIONS" -eq 0 ]; then
        echo "✅ Ultimate lifecycle audit PASSED — 0 violations"
        exit 0
    else
        echo "❌ Ultimate lifecycle audit — $VIOLATIONS violation(s)"
        exit 1
    fi
fi

# ── Diagnostic log redaction only ──
if [ "$DIAGNOSTIC_LOG_REDACTION_ONLY" -eq 1 ]; then
    # Verify no raw error.localizedDescription is logged in cleanup paths
    # Detect: log("Installer cleanup failed: \(er...")
    # The colon+space after "failed" distinguishes error interpolation from fixed message
    if git -C "$REPO_ROOT" grep -q -n -E 'log\("[a-zA-Z]+ cleanup failed: ' -- Sources/MacSteam/Ultimate/UltimateSetupCoordinator.swift 2>/dev/null; then
        echo "❌ raw error in cleanup log — 1 found"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi

    if [ "$VIOLATIONS" -eq 0 ]; then
        echo "✅ Diagnostic log redaction audit PASSED — 0 violations"
        exit 0
    else
        echo "❌ Diagnostic log redaction audit — $VIOLATIONS violation(s)"
        exit 1
    fi
fi

# ── Known lifecycle violations (scoped) ──
if [ "$PROCESS_RUNNER_ONLY" -eq 0 ]; then
    check "steam://open/main" 'steam://open/main' Sources/MacSteam
    check "activateExistingSteam" 'activateExistingSteam' Sources/MacSteam
    check "quarantineIncompleteSteamInstall" 'quarantineIncompleteSteamInstall' Sources/MacSteam

    check ".dropFirst in WineControlLane" '\.dropFirst\(' Sources/MacSteam/Processes/WineControlLane.swift

    check "mode: .detached in Installer/Ultimate" 'mode: \.detached' \
        Sources/MacSteam/Ultimate Sources/MacSteam/Installer

    check "try? in Processes/Installer" 'try\?' \
        Sources/MacSteam/Processes Sources/MacSteam/Installer

    check "Navigation TODOs" 'TODO:.*navigate|TODO:.*advance|TODO:.*dismiss' Sources/MacSteam/Views
    check "Fake timers in Views" 'asyncAfter' Sources/MacSteam/Views

    echo -n "coordinator.state assignment in Views... "
    python3 "$DIR/scripts/u1r16_static_audit.py" 2>&1

    if [ "$VIOLATIONS" -eq 0 ]; then
        echo "✅ Static audit PASSED — 0 violations" >&2
        exit 0
    else
        echo "💥 Static audit FAILED — $VIOLATIONS violation(s)" >&2
        exit 1
    fi
fi
