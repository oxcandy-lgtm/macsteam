#!/bin/bash
# U1R16-R1F7 Static Audit — fail-closed, rg required
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR" || exit 2

command -v rg >/dev/null 2>&1 || {
  echo "ERROR: rg (ripgrep) is required for U1R16 lifecycle audit"
  exit 2
}

command -v rg >/dev/null 2>&1
VIOLATIONS=0

check() {
    local desc="$1" pattern="$2"
    shift 2

    set +e
    rg -n "$pattern" "$@" > /tmp/u1r16-audit-results.txt 2>/dev/null
    local status=$?
    set -e

    if [ "$status" -eq 2 ]; then
        echo "ERROR: rg invocation failed for: $desc"
        exit 2
    fi

    if [ -s /tmp/u1r16-audit-results.txt ]; then
        echo "❌ $desc — found:"
        cat /tmp/u1r16-audit-results.txt
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        echo "✅ $desc — 0"
    fi
    rm -f /tmp/u1r16-audit-results.txt
}

echo "=== U1R16-R1F7 Static Audit ==="
echo ""

check "steam://open/main" 'steam://open/main' Sources
check "activateExistingSteam" 'activateExistingSteam' Sources
check "quarantineIncompleteSteamInstall" 'quarantineIncompleteSteamInstall' Sources
check ".dropFirst( in WineControlLane" '\.dropFirst\(' Sources/MacSteam/Processes/WineControlLane.swift
check "mode: .detached in Installer/Ultimate" 'mode: \.detached' Sources/MacSteam/Ultimate Sources/MacSteam/Installer
check "try? in Processes/Installer" 'try\?' Sources/MacSteam/Processes Sources/MacSteam/Installer
check "coordinator.state = in Views" 'coordinator\.state\s*=' Sources/MacSteam/Views
check "Navigation TODOs" 'TODO:.*navigate|TODO:.*advance|TODO:.*dismiss' Sources/MacSteam/Views
check "Fake timers in Views" 'asyncAfter' Sources/MacSteam/Views

echo ""
if [ "$VIOLATIONS" -eq 0 ]; then
    echo "🎉 Static audit PASSED — 0 violations"
    exit 0
else
    echo "💥 Static audit FAILED — $VIOLATIONS violation(s)"
    exit 1
fi
