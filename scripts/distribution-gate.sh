#!/bin/bash
# distribution-gate.sh — Distribution Boundary Gate
#
# Ensures no forbidden or unbundlable components have been added
# to the repository. Runs as part of CI.
set -eu

echo "=== Distribution Gate ==="

# Check no Steam installer in repo
if find . -name "SteamSetup.exe" -o -name "steam.exe" 2>/dev/null | grep -q .; then
  echo "FAIL: Steam installer found in repository"
  exit 1
fi

# Check no D3DMetal binaries
if find . -name "libD3DMetal*.dylib" -o -name "D3DMetal.framework" 2>/dev/null | grep -q .; then
  echo "FAIL: D3DMetal binary found"
  exit 1
fi

# Check no Microsoft redistributables
if find . -name "vcredist*.exe" -o -name "VC_redist*" 2>/dev/null | grep -q .; then
  echo "FAIL: Microsoft redistributable found"
  exit 1
fi

echo "PASS: Distribution gate passed"
