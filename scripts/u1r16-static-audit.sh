#!/bin/bash
# U1R16-R1F8 Static Audit — git grep based, zero external deps
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR" || exit 2

command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is required for static audit"
    exit 2
}

VIOLATIONS=0

check() {
    local description="$1" pattern="$2"
    shift 2

    local result_file
    result_file="$(mktemp "${TMPDIR:-/tmp}/macsteam-audit.XXXXXX")"

    set +e
    git grep -n -E -- "$pattern" -- "$@" >"$result_file" 2>&1
    local status=$?
    set -e

    case "$status" in
        0)
            echo "❌ $description — found:"
            cat "$result_file"
            VIOLATIONS=$((VIOLATIONS + 1))
            ;;
        1)
            echo "✅ $description — 0"
            ;;
        *)
            echo "ERROR: audit infrastructure failure: $description"
            cat "$result_file"
            exit 2
            ;;
    esac

    rm -f "$result_file"
}

echo "=== U1R16-R1F8 Static Audit ==="
echo ""

check "steam://open/main" 'steam://open/main' Sources
check "activateExistingSteam" 'activateExistingSteam' Sources
check "quarantineIncompleteSteamInstall" 'quarantineIncompleteSteamInstall' Sources
check ".dropFirst( in WineControlLane" '\.dropFirst\(' Sources/MacSteam/Processes/WineControlLane.swift
check "mode: .detached in Installer/Ultimate" 'mode: \.detached' Sources/MacSteam/Ultimate Sources/MacSteam/Installer
check "try? in Processes/Installer" 'try\?' Sources/MacSteam/Processes Sources/MacSteam/Installer
check "coordinator.state = in Views" 'coordinator[.]state[[:space:]]*=' Sources/MacSteam/Views
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
