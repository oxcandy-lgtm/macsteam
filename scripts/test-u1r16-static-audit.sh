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

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Static audit test PASSED"
    exit 0
else
    echo "Static audit test FAILED — $FAILURES failure(s)"
    exit 1
fi
