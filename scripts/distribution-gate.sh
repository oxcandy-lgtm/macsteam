#!/usr/bin/env bash
# distribution-gate.sh — Binary distribution gate for MacSteam.
# NUL-safe git ls-files. macOS bash 3.2 compatible.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/..")"

MANIFEST="scripts/binary-manifest.json"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

echo "=== Distribution Gate ==="

# Load allowed paths
ALLOWED=$(python3 -c "
import json
try:
    m=json.load(open('$MANIFEST'))
    for b in m.get('allowedBinaries',[]): print(b.get('path',''))
except: pass
")

# Git-tracked binary extensions (case-insensitive match)
is_binary() {
    local low; low=$(lower "$1")
    case "$low" in
        *.exe|*.dll|*.dylib|*.so|*.framework/*|*.app/*|*.pkg|*.dmg|*.msi|*.cab|*.zip|*.7z|*.tar|*.tar.gz|*.tgz|*.xz) return 0 ;;
        *) return 1 ;;
    esac
}

# Check prohibited name
is_prohibited_name() {
    local low; low=$(lower "$1")
    case "$low" in
        *steamsetup.exe*|*steam.exe*)       echo "Steam installer"; return 0 ;;
        *d3dmetal*|*gptk*|*gameporting*)    echo "D3DMetal/GPTK";  return 0 ;;
        *vcredist*|*vc_redist*|*directx*|*dxsetup*) echo "MS redist"; return 0 ;;
        *) return 1 ;;
    esac
}

while IFS= read -r -d '' file; do
    is_binary "$file" || continue
    prohibited=$(is_prohibited_name "$file" || true)
    if [ -n "$prohibited" ]; then
        fail "prohibited ($prohibited): $file"
    elif echo "$ALLOWED" | grep -qxF "$file"; then
        pass "allowed: $file"
    else
        fail "unregistered binary: $file"
    fi
done < <(git ls-files -z --cached --others --exclude-standard \
    ':(exclude).gitmodules' ':(exclude).gitattributes' 2>/dev/null || echo -n "")

echo ""
echo "=== Summary ==="
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -gt 0 ] && { echo "FAILED"; exit 1; }
echo "PASS"
