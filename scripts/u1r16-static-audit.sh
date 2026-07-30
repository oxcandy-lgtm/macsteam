#!/bin/bash
# U1R16 Static Audit — exit 0 if clean, exit 1 on any violation
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR" || exit 1

VIOLATIONS=0

check() {
    local desc="$1" pattern="$2" path="$3"
    local results
    results=$(rg -n "$pattern" "$path" 2>/dev/null || true)
    if [ -n "$results" ]; then
        echo "❌ $desc — found:"
        echo "$results"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        echo "✅ $desc — 0"
    fi
}

echo "=== U1R16 Static Audit ==="
echo ""

check "steam://open/main" 'steam://open/main' Sources
check "activateExistingSteam" 'activateExistingSteam' Sources
check "quarantineIncompleteSteamInstall" 'quarantineIncompleteSteamInstall' Sources
check "dropFirst in WineControlLane" 'dropFirst' Sources/MacSteam/Processes/WineControlLane.swift
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
