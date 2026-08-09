#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MacsTeam Developer-Local App Sync (U1R18-R13-FIX1-FIX1 §8)
#
# Builds the current repo HEAD into a bounded user-local .app and atomically
# replaces the previous developer app using a fail-closed publication
# transaction. Never writes to /Applications, never uses sudo, never bundles
# Steam/Wine/CloverPit binaries, and never leaves the previous working app in a
# half-written state.
#
# Fail-closed publication order (candidate verified BEFORE touching the
# installed app; old backup deleted only AFTER final verification):
#   1. build candidate
#   2. construct complete candidate .app
#   3. validate required executable/resources
#   4. read candidate embedded MacsTeamBuildSHA
#   5. require candidate SHA == exact repository HEAD
#   6. only then enter publication transaction
#   7. stage candidate as a same-filesystem sibling under ${HOME}/Applications
#   8. move existing app to a sibling backup if present
#   9. rename verified staged candidate to final target
#  10. verify published app
#  11. only after final verification succeeds delete backup
#
# If any operation after old-app displacement fails, the old app is restored,
# the final result is non-zero, and MATCH=true is never claimed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacsTeam Dev.app"
APPS_DIR="${HOME}/Applications"
APP_TARGET="${APPS_DIR}/${APP_NAME}"
CONFIG="${MACSTEAM_DEV_SYNC_CONFIG:-release}"
# Construction scratch may live in /tmp; the final rename/backup are staged as
# same-filesystem siblings under the target parent.
TEMP_BASE="$(mktemp -d /tmp/macsteam-dev-sync.XXXXXX)"

# Publication transaction state (same-filesystem siblings under APPS_DIR).
STAGED_DIR=""
BACKUP_DIR=""
OLD_DISPLACED=0
PUBLISHED_OK=0

# Fail-closed trap: after the old app is displaced, restore it on any
# ordinary failure / INT / TERM. Never delete the only known-good backup before
# publication verification completes.
restore_old_app() {
  if [ "$OLD_DISPLACED" = "1" ] && [ "$PUBLISHED_OK" != "1" ]; then
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/$APP_NAME" ]; then
      rm -rf "$APP_TARGET" 2>/dev/null || true
      mv "$BACKUP_DIR/$APP_NAME" "$APP_TARGET" 2>/dev/null || true
      OLD_DISPLACED=0
    fi
  fi
}

cleanup() {
  restore_old_app
  rm -rf "$TEMP_BASE"
  if [ -n "$STAGED_DIR" ]; then rm -rf "$STAGED_DIR" 2>/dev/null || true; fi
  if [ -n "$BACKUP_DIR" ]; then rm -rf "$BACKUP_DIR" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

# --- 1. Worktree must be clean (fail closed) ---
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "dev-sync: not a git repository at $REPO_ROOT" >&2
  exit 1
fi
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  echo "dev-sync: worktree is dirty; refusing to sync (sync must be from a clean HEAD)" >&2
  exit 1
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# Test-only seams (unset in production; used by scripts/test-dev-app-sync.sh to
# deterministically exercise fail-closed publication paths).
CANDIDATE_SHA_FOR_BUNDLE="$HEAD_SHA"
if [ "${MACSTEAM_DEV_SYNC_FORCE_CANDIDATE_MISMATCH:-0}" = "1" ]; then
  CANDIDATE_SHA_FOR_BUNDLE="0000000000000000000000000000000000000000"
fi
SKIP_RES=0
if [ "${MACSTEAM_DEV_SYNC_SKIP_RES:-0}" = "1" ]; then
  SKIP_RES=1
fi
FORCE_POSTPUBLISH_MISMATCH="${MACSTEAM_DEV_SYNC_FORCE_POSTPUBLISH_MISMATCH:-0}"

# --- 2. Build + construct the complete candidate .app (construction scratch) ---
BUNDLE_DIR="${TEMP_BASE}/${APP_NAME}"
MACH_DIR="${BUNDLE_DIR}/Contents/MacOS"
RES_DIR="${BUNDLE_DIR}/Contents/Resources"
mkdir -p "$MACH_DIR" "$RES_DIR"

BIN_SRC=""
(
  cd "$REPO_ROOT"
  swift build -c "$CONFIG" >/dev/null 2> "${TEMP_BASE}/build.log" || {
    echo "dev-sync: build failed; existing app preserved" >&2
    tail -n 20 "${TEMP_BASE}/build.log" >&2
    exit 1
  }
  BIN_SRC="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null)/MacsTeam"
  printf '%s' "$BIN_SRC" > "${TEMP_BASE}/binpath"
)
BIN_SRC="$(cat "${TEMP_BASE}/binpath" 2>/dev/null || true)"
if [ ! -x "$BIN_SRC" ]; then
  echo "dev-sync: built executable not found at $BIN_SRC" >&2
  exit 1
fi

cp "$BIN_SRC" "$MACH_DIR/MacsTeam"

# Required SwiftPM resources (Recipes). Bounded copy; no Steam/Wine binaries.
if [ "$SKIP_RES" = "1" ]; then
  : # test-only: omit Recipes to exercise the incomplete-candidate guard
elif [ -d "$REPO_ROOT/Sources/MacSteam/Resources/Recipes" ]; then
  cp -R "$REPO_ROOT/Sources/MacSteam/Resources/Recipes" "$RES_DIR/Recipes"
fi

# --- 3. Info.plist with embedded build identity ---
cat > "${BUNDLE_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MacsTeam</string>
  <key>CFBundleIdentifier</key><string>com.macsteam.developer</string>
  <key>CFBundleName</key><string>MacsTeam Dev</string>
  <key>CFBundleDisplayName</key><string>MacsTeam Dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MacsTeamBuildSHA</key><string>${CANDIDATE_SHA_FOR_BUNDLE}</string>
  <key>MacsTeamBuildChannel</key><string>Developer Local</string>
</dict>
</plist>
PLIST

# --- 4 + 5. Validate candidate BEFORE touching the installed app: executable,
# required resources, and embedded SHA must equal the exact repository HEAD. ---
if [ ! -x "$MACH_DIR/MacsTeam" ]; then
  echo "dev-sync: candidate incomplete (executable missing); no replace" >&2
  exit 1
fi
if [ ! -d "$RES_DIR/Recipes" ]; then
  echo "dev-sync: candidate incomplete (Recipes resource missing); no replace" >&2
  exit 1
fi
CANDIDATE_SHA="$(defaults read "${BUNDLE_DIR}/Contents/Info" MacsTeamBuildSHA 2>/dev/null || true)"
if [ "$CANDIDATE_SHA" != "$HEAD_SHA" ] && [ "$FORCE_POSTPUBLISH_MISMATCH" != "1" ]; then
  echo "dev-sync: candidate SHA mismatch (candidate=$CANDIDATE_SHA expected=$HEAD_SHA); no replace" >&2
  exit 1
fi

# --- 6 + 7. Enter publication: stage candidate as a same-filesystem sibling
# under the target parent, so the final rename is same-filesystem. ---
mkdir -p "${APPS_DIR}"
STAGED_DIR="$(mktemp -d "${APPS_DIR}/.${APP_NAME}.staging.XXXXXX")"
mv "$BUNDLE_DIR" "${STAGED_DIR}/${APP_NAME}"

# --- 8. Move existing app to a same-filesystem sibling backup if present. ---
if [ -d "$APP_TARGET" ]; then
  BACKUP_DIR="$(mktemp -d "${APPS_DIR}/.${APP_NAME}.backup.XXXXXX")"
  mv "$APP_TARGET" "${BACKUP_DIR}/${APP_NAME}"
  OLD_DISPLACED=1
fi

# --- 9. Rename the verified staged candidate to the final target. ---
if ! mv "${STAGED_DIR}/${APP_NAME}" "$APP_TARGET"; then
  restore_old_app
  echo "dev-sync: publication rename failed; old app restored" >&2
  exit 1
fi
rmdir "$STAGED_DIR" 2>/dev/null || true
STAGED_DIR=""

# --- 10. Verify the published app (executable + embedded SHA). ---
if [ ! -x "$APP_TARGET/Contents/MacOS/MacsTeam" ]; then
  restore_old_app
  echo "dev-sync: final verification failed (executable missing); old app restored" >&2
  exit 1
fi
EMBEDDED="$(defaults read "$APP_TARGET/Contents/Info" MacsTeamBuildSHA 2>/dev/null || true)"
if [ "$EMBEDDED" != "$HEAD_SHA" ]; then
  restore_old_app
  echo "dev-sync: final verification failed (embedded SHA mismatch); old app restored" >&2
  exit 1
fi

# --- 11. Final verification succeeded: commit publication, then delete backup. ---
PUBLISHED_OK=1
if [ "$OLD_DISPLACED" = "1" ] && [ -n "$BACKUP_DIR" ]; then
  rm -rf "$BACKUP_DIR"
  BACKUP_DIR=""
fi
OLD_DISPLACED=0

# Output the canonical identity result only after final verification.
echo "INSTALLED_HEAD=$HEAD_SHA"
echo "APP_PATH=$APP_TARGET"
echo "MATCH=true"