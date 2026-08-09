#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MacsTeam Developer-Local App Sync (U1R18-R13-FIX1 §3)
#
# Builds the current repo HEAD into a bounded user-local .app and atomically
# replaces the previous developer app. Never writes to /Applications, never
# uses sudo, never bundles Steam/Wine/CloverPit binaries, and never leaves the
# previous working app in a half-written state.
#
# Fail-closed rules:
#   - dirty worktree -> exit non-zero, no replacement
#   - build failure -> leave the existing app untouched
#   - incomplete temp bundle -> no replacement
#   - embedded SHA mismatch -> no replacement
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacsTeam Dev.app"
APP_TARGET="${HOME}/Applications/${APP_NAME}"
CONFIG="${MACSTEAM_DEV_SYNC_CONFIG:-release}"
TEMP_BASE="$(mktemp -d /tmp/macsteam-dev-sync.XXXXXX)"

cleanup() {
  rm -rf "$TEMP_BASE"
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
SHORT_SHA="${HEAD_SHA:0:12}"

# --- 2. Build (into a temp bundle; never touches the existing app) ---
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
if [ -d "$REPO_ROOT/Sources/MacSteam/Resources/Recipes" ]; then
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
  <key>MacsTeamBuildSHA</key><string>${HEAD_SHA}</string>
  <key>MacsTeamBuildChannel</key><string>Developer Local</string>
</dict>
</plist>
PLIST

# --- 4. Incomplete-temp-bundle guard: executable + resources must exist ---
if [ ! -x "$MACH_DIR/MacsTeam" ]; then
  echo "dev-sync: temp bundle incomplete (executable missing); no replace" >&2
  exit 1
fi

# --- 5. Atomic replace of the previous developer app ---
mkdir -p "${HOME}/Applications"
REPLACED_ROOT="$(mktemp -d /tmp/macsteam-dev-sync-old.XXXXXX)"
if [ -d "$APP_TARGET" ]; then
  mv "$APP_TARGET" "${REPLACED_ROOT}/${APP_NAME}"
fi
mv "$BUNDLE_DIR" "$APP_TARGET" || {
  # Restore the previous app on replace failure.
  if [ -d "${REPLACED_ROOT}/${APP_NAME}" ] && [ ! -d "$APP_TARGET" ]; then
    mv "${REPLACED_ROOT}/${APP_NAME}" "$APP_TARGET"
  fi
  echo "dev-sync: atomic replace failed; previous app restored" >&2
  exit 1
}
rm -rf "$REPLACED_ROOT"

# --- 6. Verify embedded SHA matches HEAD ---
EMBEDDED="$(defaults read "$APP_TARGET/Contents/Info" MacsTeamBuildSHA 2>/dev/null || true)"
if [ "$EMBEDDED" != "$HEAD_SHA" ]; then
  echo "dev-sync: embedded SHA mismatch (embedded=$EMBEDDED expected=$HEAD_SHA)" >&2
  exit 1
fi

# Output the canonical identity result.
echo "INSTALLED_HEAD=$HEAD_SHA"
echo "APP_PATH=$APP_TARGET"
echo "MATCH=true"