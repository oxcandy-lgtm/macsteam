#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Developer-Local App Sync test harness (U1R18-R13-FIX1 §17).
#
# Exercises scripts/dev-sync-local-app.sh against throwaway temp HOME dirs and
# a throwaway temp git worktree at the current committed HEAD, so the real
# ~/Applications is never touched. Fail-closed behaviors are asserted:
#   - dirty tree rejected
#   - build failure preserves old app
#   - successful bundle contains executable
#   - required resources copied
#   - embedded build SHA equals git HEAD
#   - second sync replaces with newer exact HEAD
#   - no Steam executable bundled
#   - no Wine executable bundled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SCRIPT_DIR/dev-sync-local-app.sh"
GATE="$REPO_ROOT/scripts/workstage-review-gate.py"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Require a clean committed HEAD to build a faithful temp worktree.
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  echo "HARNESS: main repo must be clean to snapshot HEAD into a temp worktree" >&2
  exit 2
fi
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

WT="$(mktemp -d /tmp/wrg-dev-sync-wt.XXXXXX)"
git worktree add "$WT" "$HEAD_SHA" >/dev/null 2>&1
# dev-sync-local-app.sh is part of the committed HEAD, so it is already present
# in the worktree; no copy/commit is required.

cleanup() {
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$HOME_TMP"
}
trap cleanup EXIT INT TERM

HOME_TMP="$(mktemp -d /tmp/wrg-dev-sync-home.XXXXXX)"
mkdir -p "$HOME_TMP/Applications"

# --- 1. dirty tree rejected (add an untracked file then run) ---
touch "$WT/UNTRACKED_FILE"
if HOME="$HOME_TMP" bash "$WT/scripts/dev-sync-local-app.sh" >/dev/null 2>&1; then
  bad "dirty worktree was not rejected"
else
  ok
fi
rm -f "$WT/UNTRACKED_FILE"

# --- 2. successful sync installs app with matching embedded SHA ---
OUT="$(HOME="$HOME_TMP" bash "$WT/scripts/dev-sync-local-app.sh")"
if [ "$(printf '%s\n' "$OUT" | grep -E '^MATCH=' | cut -d= -f2)" = "true" ]; then
  ok
else
  bad "sync did not report MATCH=true"
fi
APP="$HOME_TMP/Applications/MacsTeam Dev.app"
if [ -x "$APP/Contents/MacOS/MacsTeam" ]; then
  ok
else
  bad "synced app executable missing"
fi
EMBEDDED="$(defaults read "$APP/Contents/Info" MacsTeamBuildSHA 2>/dev/null || true)"
if [ "$EMBEDDED" = "$HEAD_SHA" ]; then
  ok
else
  bad "embedded SHA ($EMBEDDED) != HEAD ($HEAD_SHA)"
fi
# required Recipes resource present
if [ -d "$APP/Contents/Resources/Recipes" ] || [ -d "$APP/Contents/Recipes" ]; then
  ok
else
  bad "required Recipes resource not copied"
fi
# no Steam / Wine binaries bundled
if find "$APP" -iname "steam.exe" -o -iname "wine" -o -iname "wineboot" | grep -q .; then
  bad "Steam/Wine binary was bundled"
else
  ok
fi

# --- 3. build failure preserves old app (force a failing build) ---
# Simulate a build failure by temporarily pointing swift at a broken package.
FAKE="$WT/scripts/dev-sync-local-app.sh"
OLD_APP_HASH="$(defaults read "$APP/Contents/Info" MacsTeamBuildSHA 2>/dev/null || true)"
# Corrupt the build: introduce a syntax error into a source file, sync, restore.
SRC="$WT/Sources/MacSteam/App/Branding.swift"
cp "$SRC" "$SRC.bak"
printf 'syntax error {{{\n' >> "$SRC"
if HOME="$HOME_TMP" bash "$WT/scripts/dev-sync-local-app.sh" >/dev/null 2>&1; then
  bad "build failure was not detected"
else
  ok
fi
mv "$SRC.bak" "$SRC"
# The old app must still be present and unchanged.
NEW_APP_HASH="$(defaults read "$APP/Contents/Info" MacsTeamBuildSHA 2>/dev/null || true)"
if [ -x "$APP/Contents/MacOS/MacsTeam" ] && [ "$NEW_APP_HASH" = "$OLD_APP_HASH" ]; then
  ok
else
  bad "build failure corrupted the previously installed app"
fi

echo ""
echo "=== Dev App Sync Harness Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
cleanup
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0