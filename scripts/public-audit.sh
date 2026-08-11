#!/usr/bin/env bash
# public-audit.sh — Pre-publication security scan
#
# Scans only git‑tracked files to avoid hitting build artifacts
# or stale fixtures.  Tests are NOT blanket‑excluded — secrets
# in test fixtures must be constructed dynamically or listed in
# the allowlist below.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
PASS=0
FAIL=0
WARN=0

# ––– helpers –––

check() {
    local label="$1" result="$2"
    if [ "$result" = "pass" ]; then
        echo -e "${GREEN}[PASS]${NC} $label"
        PASS=$((PASS+1))
    elif [ "$result" = "warn" ]; then
        echo -e "${YELLOW}[WARN]${NC} $label"
        WARN=$((WARN+1))
    else
        echo -e "${RED}[FAIL]${NC} $label"
        FAIL=$((FAIL+1))
    fi
}

# Format a WARN with location info for manual inspection.
warn_detail() {
    local category="$1" file="$2" line="$3" value="$4"
    echo -e "  ${YELLOW}→${NC} ${category}: ${file}:${line}"
    echo -e "    value: ${value}"
}

# List all git‑tracked files (ignoring submodules, build artifacts).
git_ls() {
    git ls-files -z --cached --others --exclude-standard \
        ':(exclude).gitmodules' ':(exclude).gitattributes'
}

# Search inside git‑tracked files only.
git_grep() {
    local pattern="$1"; shift
    git_ls | tr '\0' '\n' | xargs grep -HnIE "$pattern" "$@" 2>/dev/null || true
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Public Audit for MacSteam (git‑tracked only) ==="
echo ""

# ––– Private keys –––
echo "--- Private Keys ---"
# Allowlisted:
#   Sources/MacSteam/Services/PathRedactor.swift — detection-pattern constants
#   Tests/PathRedactorTests.swift                — known test fixture
if git_grep 'BEGIN (PRIVATE|RSA PRIVATE|OPENSSH PRIVATE|EC PRIVATE) KEY' \
    | grep -v 'Sources/MacSteam/Services/PathRedactor\.swift' \
    | grep -v 'Tests/PathRedactorTests\.swift'; then
    check "No private keys in repository" "fail"
else
    check "No private keys in repository" "pass"
fi

# ––– Credentials & tokens –––
echo "--- Credentials & Tokens ---"
# Exclude the audit script itself (patterns appear inline) and test fixtures.
if git_grep 'github_pat_|ghp_|gho_|ghu_|ghs_|ghr_' \
    | grep -v 'scripts/public-audit\.sh' \
    | grep -v 'Tests/PathRedactorTests\.swift'; then
    check "No GitHub tokens in repository" "fail"
else
    check "No GitHub tokens in repository" "pass"
fi

if git_grep 'AKIA[0-9A-Z]\{16\}' \
    | grep -v 'Tests/PathRedactorTests\.swift'; then
    check "No AWS keys in repository" "fail"
else
    check "No AWS keys in repository" "pass"
fi

if git_grep 'xox[baprs]-' \
    | grep -v 'Tests/PathRedactorTests\.swift'; then
    check "No Slack tokens in repository" "fail"
else
    check "No Slack tokens in repository" "pass"
fi

if git_grep 'Authorization:*** |client_secret|refresh_token|access_token' \
    | grep -v 'scripts/public-audit\\.sh' \
    | grep -v 'Tests/PathRedactorTests\\.swift' \
    | grep -v 'Sources/MacSteam/Services/PathRedactor\\.swift' \
    | grep -v 'Sources/MacSteam/Security/SteamSensitiveDataPolicy\\.swift'; then
    check "No authorization secrets in repository" "fail"
else
    check "No authorization secrets in repository" "pass"
fi

# ––– Internal project names –––
echo "--- Internal Project Names ---"
for term in CCL CCLLM CCLMUX KARASI BOOTMUX SAI; do
    matches=$(git_grep "$term" \
        | grep -v 'scripts/public-audit\.sh' || true)
    if [ -n "$matches" ]; then
        while IFS= read -r line; do
            warn_detail "internal name '$term'" "$line" "" ""
        done <<< "$matches"
        check "No internal name '$term' in source" "fail"
    else
        check "No internal name '$term' in source" "pass"
    fi
done

# ––– Email addresses –––
echo "--- Email Addresses ---"
# Tests are NOT excluded — test data must use @example.* domains only.
matches=$(git_grep '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' \
    | grep -v '@example\.\(com\|org\|net\|invalid\)' \
    | grep -v 'spdx\.org' \
    | grep -v 'scripts/public-audit\.sh' || true)
if [ -n "$matches" ]; then
    while IFS= read -r line; do
        file="${line%%:*}"
        rest="${line#*:}"
        lineno="${rest%%:*}"
        raw="${rest#*:}"
        redacted=$(echo "$raw" | sed 's/[a-zA-Z0-9._%+-]*@[a-zA-Z0-9.-]*\.[a-zA-Z]*/***@***.***/g')
        warn_detail "email" "$file" "$lineno" "$redacted"
    done <<< "$matches"
    check "No personal email addresses in repository" "fail"
else
    check "No personal email addresses in repository" "pass"
fi

# ––– Absolute personal paths –––
echo "--- Personal Paths ---"
# Tests are NOT excluded — test data must use /Users/example/ only.
matches=$(git_grep '/Users/[A-Za-z0-9_-]+/' \
    | grep -v '/Users/example' \
    | grep -v '/Users/Shared' \
    | grep -v '/Users/Guest' \
    | grep -v '/Users/test' || true)
if [ -n "$matches" ]; then
    while IFS= read -r line; do
        file="${line%%:*}"
        rest="${line#*:}"
        lineno="${rest%%:*}"
        raw="${rest#*:}"
        redacted=$(echo "$raw" | sed 's|/Users/[A-Za-z0-9_-]*|/Users/<redacted>|g')
        warn_detail "personal path" "$file" "$lineno" "$redacted"
    done <<< "$matches"
    check "No real user paths in source" "fail"
else
    check "No real user paths in source" "pass"
fi

# ––– Apple signatures –––
echo "--- Apple Signatures ---"
if git_ls | tr '\0' '\n' | grep -q '\.mobileprovision$'; then
    check "No .mobileprovision files" "fail"
else
    check "No .mobileprovision files" "pass"
fi
if git_ls | tr '\0' '\n' | grep -q '\.p12$'; then
    check "No .p12 files" "fail"
else
    check "No .p12 files" "pass"
fi
if git_ls | tr '\0' '\n' | grep -q '\.dSYM$'; then
    check "No .dSYM files" "fail"
else
    check "No .dSYM files" "pass"
fi

# Check for Development Team ID in tracked plists
if git_ls | tr '\0' '\n' | grep '\.plist$' | xargs grep -HE 'DEVELOPMENT_TEAM|[A-Z0-9]\{10\}\.' 2>/dev/null \
    | grep -v 'DEVELOPMENT_TEAM = ""'; then
    check "No hardcoded Development Team ID" "fail"
else
    check "No hardcoded Development Team ID" "pass"
fi

# ––– Proprietary binaries –––
echo "--- Proprietary Binaries ---"
if git_ls | tr '\0' '\n' | grep -qE '\.(dll|exe|so|dylib)$'; then
    check "No proprietary binaries in repository" "fail"
else
    check "No proprietary binaries in repository" "pass"
fi

# ––– Xcode user data –––
echo "--- Xcode User Data ---"
if git_ls | tr '\0' '\n' | grep -q 'xcuserdata'; then
    check "No xcuserdata in repository" "fail"
else
    check "No xcuserdata in repository" "pass"
fi

# ––– AI agent scratch files –––
echo "--- AI Agent Scratch Files ---"
if git_ls | tr '\0' '\n' | grep -q '\.hermes/'; then
    check "No .hermes tracked files in repository" "fail"
else
    check "No .hermes tracked files in repository" "pass"
fi

# ––– U1R18 canonical PR truth authority –––
echo "--- U1R18 Canonical PR Truth Authority ---"
if bash scripts/test-u1r18-pr-truth.sh >/dev/null 2>&1; then
    check "Test U1R18 canonical PR truth authority" "pass"
else
    check "Test U1R18 canonical PR truth authority" "fail"
fi

# ––– U1R18 public product truth authority –––
echo "--- Public Product Truth Authority ---"
if bash scripts/test-public-product-truth-audit.sh >/dev/null 2>&1; then
    check "Public product truth authority" "pass"
else
    check "Public product truth authority" "fail"
fi

# ––– U1R18-R11 local runtime acceptance authority –––
echo "--- Local Runtime Acceptance Audit ---"
if python3 scripts/local-runtime-acceptance-audit.py >/dev/null 2>&1; then
    check "Local runtime acceptance audit" "pass"
else
    check "Local runtime acceptance audit" "fail"
fi

echo "--- Local Runtime Acceptance Mutation Harness ---"
if bash scripts/test-local-runtime-acceptance-audit.sh >/dev/null 2>&1; then
    check "Local runtime acceptance mutation harness" "pass"
else
    check "Local runtime acceptance mutation harness" "fail"
fi

# ––– Summary –––
echo ""
echo "=== Summary ==="
echo -e "${GREEN}Pass:${NC} $PASS  ${RED}Fail:${NC} $FAIL  ${YELLOW}Warn:${NC} $WARN"
if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}FAILED: $FAIL blocking items must be resolved before publication.${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    # Warnings are informational — they do not block publication.
    echo -e "${YELLOW}WARNINGS: $WARN non-blocking items found.${NC}"
    exit 0
else
    echo -e "${GREEN}Audit passed.${NC}"
    exit 0
fi
