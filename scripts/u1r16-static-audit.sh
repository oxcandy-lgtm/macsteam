#!/bin/bash
# U1R16-R1F6 Static Audit — fail-closed
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR" || exit 2

# Use ripgrep if available, fallback to grep
if command -v rg >/dev/null 2>&1; then
    search_tool() { rg -n "$1" "${@:2}" 2>/dev/null || true; }
else
    search_tool() { grep -rn "$1" "${@:2}" 2>/dev/null || true; }
fi

VIOLATIONS=0

check() {
    local desc="$1" pattern="$2"
    shift 2

    local results
    results=$(search_tool "$pattern" "$@")

    if [ -n "$results" ]; then
        echo "❌ $desc — found:"
        echo "$results"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        echo "✅ $desc — 0"
    fi
}

echo "=== U1R16-R1F6 Static Audit ==="
echo ""

check "steam://open/main" 'steam://open/main' Sources
check "activateExistingSteam" 'activateExistingSteam' Sources
check "quarantineIncompleteSteamInstall" 'quarantineIncompleteSteamInstall' Sources
check ".dropFirst( in WineControlLane" '\.dropFirst(' Sources/MacSteam/Processes/WineControlLane.swift
check "mode: .detached in Installer/Ultimate" 'mode: \.detached' Sources/MacSteam/Ultimate Sources/MacSteam/Installer
check "try? in Processes/Installer" 'try?' Sources/MacSteam/Processes Sources/MacSteam/Installer
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
