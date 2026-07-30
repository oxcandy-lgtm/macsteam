#!/bin/bash
# U1R16-R1F28 Static Audit — git grep + Python scanner
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR" || exit 2
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

usage() { echo "Usage: $0 [--fix]"; exit 1; }
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1

red() { printf '\e[31m%s\e[0m\n' "$1"; }
green() { printf '\e[32m%s\e[0m\n' "$1"; }

VIOLATIONS=0
check() {
    local label="$1" pattern="$2" pathspec="${3:-.}"
    if [ "$FIX" = 1 ]; then
        git grep -l -E -- "$pattern" -- "$pathspec" 2>/dev/null | while read -r f; do
            sed -i '' -E "/$pattern/d" "$f"
        done
        return
    fi
    local matches
    matches=$(git grep -c -E -- "$pattern" -- "$pathspec" 2>/dev/null || true)
    if [ -n "$matches" ]; then
        local count
        count=$(echo "$matches" | awk -F: '{s+=$2}END{print s+0}')
        if [ "$count" -gt 0 ]; then
            red "❌ $label — found:"
            git grep -n -E -- "$pattern" -- "$pathspec" 2>/dev/null | sed 's/^/    /'
            VIOLATIONS=$((VIOLATIONS + count))
        else
            green "✅ $label — 0"
        fi
    else
        green "✅ $label — 0"
    fi
}

# ── Production ProcessRunner guards ──
check "readToEnd in ProcessRunner" 'readToEnd' Sources/MacSteam/Core/ProcessRunner.swift
check "ThreadSafeData in ProcessRunner" 'ThreadSafeData' Sources/MacSteam/Core/ProcessRunner.swift
check "kill in ProcessRunner" ']kill(' Sources/MacSteam/Core/ProcessRunner.swift

# ── Existing lifecycle violations (known) ──
check "steam://open/main" 'steam://open/main' Sources/MacSteam
check "activateExistingSteam" 'activateExistingSteam' Sources/MacSteam
check "quarantineIncompleteSteamInstall" 'quarantineIncompleteSteamInstall' Sources/MacSteam
check ".dropFirst in WineControlLane" '\.dropFirst\(' Sources/MacSteam/Processes/WineControlLane.swift
check "mode: .detached in Installer/Ultimate" 'mode: \.detached' Sources/MacSteam
check "try? in Processes/Installer" 'try\?' Sources/MacSteam/Processes
check "Navigation TODOs" 'TODO:.*navigate|TODO:.*advance|TODO:.*dismiss' Sources/MacSteam/Views
check "Fake timers in Views" 'asyncAfter' Sources/MacSteam/Views

# ── coordinator.state detection (Python scanner) ──
echo -n "coordinator.state assignment in Views... "
python3 scripts/u1r16_static_audit.py 2>&1

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "💥 Static audit FAILED — $VIOLATIONS violation(s)" >&2
    exit 1
fi

echo "✅ Static audit PASSED — 0 violations" >&2
exit 0
