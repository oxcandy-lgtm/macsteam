#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MacsTeam Developer-Local Launch (U1R18-R13-FIX1 §3.4)
#
# sync -> verify embedded SHA -> open the synced developer app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="${REPO_ROOT}/scripts/dev-sync-local-app.sh"
APP_TARGET="${HOME}/Applications/MacsTeam Dev.app"

OUT="$("$SYNC")"
echo "$OUT"
if [ "$(printf '%s\n' "$OUT" | grep -E '^MATCH=' | cut -d= -f2)" != "true" ]; then
  echo "dev-run: sync did not verify embedded SHA; not opening" >&2
  exit 1
fi

if [ ! -x "$APP_TARGET/Contents/MacOS/MacsTeam" ]; then
  echo "dev-run: synced app executable missing at $APP_TARGET" >&2
  exit 1
fi

open "$APP_TARGET"
echo "dev-run: opened $APP_TARGET"