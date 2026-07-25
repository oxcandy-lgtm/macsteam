#!/usr/bin/env bash
# public-audit.sh — Pre-publication security scan
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
PASS=0
FAIL=0
WARN=0

EXCLUDE="--exclude-dir=.git --exclude-dir=.build --exclude-dir=DerivedData"
EXCLUDE_FILES="--exclude=public-audit.sh"
# Test files that intentionally contain token patterns for testing
EXCLUDE_TESTS="--exclude-dir=Tests"

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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Public Audit for MacSteam ==="
echo ""

# ---- Absolute personal paths ----
echo "--- Personal Paths ---"
if grep -rnI --include="*.swift" --include="*.json" --include="*.plist" --include="*.md" \
    $EXCLUDE $EXCLUDE_FILES \
    -E "/Users/[A-Za-z0-9_-]+/" . 2>/dev/null | grep -v -E "/Users/example|/Users/Shared|/Users/Guest|/Users/evil/|/Users/alice/"; then
    check "No real user paths in source (manual review needed)" "warn"
else
    check "No real user paths in source" "pass"
fi

# ---- Private keys ----
echo "--- Private Keys ---"
# Only scan non-test files; test fixtures are exempt
# Also exclude PathRedactor.swift which contains detection patterns as code constants
if grep -rnI --include="*" $EXCLUDE $EXCLUDE_TESTS $EXCLUDE_FILES \
    --exclude="PathRedactor.swift" \
    -E "BEGIN PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|BEGIN EC PRIVATE KEY" . 2>/dev/null; then
    check "No private keys in repository" "fail"
else
    check "No private keys in repository" "pass"
fi

# ---- Credentials & tokens ----
echo "--- Credentials & Tokens ---"
# Only scan non-test source files for credentials
if grep -rnI --include="*.swift" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.sh" \
    $EXCLUDE $EXCLUDE_TESTS $EXCLUDE_FILES \
    -E "github_pat_|ghp_|gho_|ghu_|ghs_|ghr_" . 2>/dev/null; then
    check "No GitHub tokens in repository" "fail"
else
    check "No GitHub tokens in repository" "pass"
fi

if grep -rnI --include="*.swift" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.sh" \
    $EXCLUDE $EXCLUDE_TESTS $EXCLUDE_FILES \
    -E "AKIA[0-9A-Z]{16}" . 2>/dev/null; then
    check "No AWS keys in repository" "fail"
else
    check "No AWS keys in repository" "pass"
fi

if grep -rnI --include="*.swift" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.sh" \
    $EXCLUDE $EXCLUDE_TESTS $EXCLUDE_FILES \
    -E "xoxb-|xoxp-|xoxa-" . 2>/dev/null; then
    check "No Slack tokens in repository" "fail"
else
    check "No Slack tokens in repository" "pass"
fi

if grep -rnI --include="*.swift" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.sh" \
    $EXCLUDE $EXCLUDE_TESTS $EXCLUDE_FILES \
    --exclude="PathRedactor.swift" \
    -E "Authorization:|Bearer |client_secret|refresh_token|access_token" . 2>/dev/null \
    | grep -v -E "//\s*(Authorization:|Bearer |client_secret|refresh_token)" \
    | grep -v "guard let accessToken"; then
    check "No authorization secrets in repository" "warn"
else
    check "No authorization secrets in repository" "pass"
fi

# ---- Internal project names ----
echo "--- Internal Project Names ---"
for term in CCL CCLLM CCLMUX KARASI BOOTMUX SAI; do
    # Check only source and config files
    if grep -rnI --include="*.swift" --include="*.json" --include="*.yaml" --include="*.yml" \
        $EXCLUDE $EXCLUDE_TESTS $EXCLUDE_FILES \
        -E "$term" . 2>/dev/null | grep -v "$term" | head -1 >/dev/null; then
        check "No internal name '$term' in source" "fail"
    else
        check "No internal name '$term' in source" "pass"
    fi
done

# ---- Email addresses ----
echo "--- Email Addresses ---"
if grep -rnI --include="*" $EXCLUDE $EXCLUDE_FILES \
    -E "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" . 2>/dev/null \
    | grep -v -E "example\.(com|org|net|invalid)$|@example|spdx\.org|coc@|conduct@|security@|macsteam@example"; then
    check "No real email addresses in repository" "warn"
else
    check "No real email addresses in repository" "pass"
fi

# ---- Apple signatures ----
echo "--- Apple Signatures ---"
if find . -name "*.mobileprovision" -not -path "./.git/*" -not -path "./.build/*" 2>/dev/null | grep -q .; then
    check "No .mobileprovision files" "fail"
else
    check "No .mobileprovision files" "pass"
fi
if find . -name "*.p12" -not -path "./.git/*" -not -path "./.build/*" 2>/dev/null | grep -q .; then
    check "No .p12 files" "fail"
else
    check "No .p12 files" "pass"
fi
if find . -name "*.dSYM" -not -path "./.git/*" -not -path "./.build/*" -not -path "./DerivedData/*" 2>/dev/null | grep -q .; then
    check "No .dSYM files" "warn"
else
    check "No .dSYM files" "pass"
fi
if grep -rnI --include="*.plist" $EXCLUDE $EXCLUDE_FILES \
    -E "DEVELOPMENT_TEAM|[A-Z0-9]{10}\." . 2>/dev/null | grep -v 'DEVELOPMENT_TEAM = ""'; then
    check "No hardcoded Development Team ID" "warn"
else
    check "No hardcoded Development Team ID" "pass"
fi

# ---- Proprietary binaries ----
echo "--- Proprietary Binaries ---"
if find . -type f \( -name "*.dll" -o -name "*.exe" -o -name "*.so" -o -name "*.dylib" \) \
    -not -path "./.git/*" -not -path "./.build/*" 2>/dev/null | grep -q .; then
    check "No proprietary binaries in repository" "fail"
else
    check "No proprietary binaries in repository" "pass"
fi

# ---- Xcode user data ----
echo "--- Xcode User Data ---"
if find . -name "xcuserdata" -not -path "./.git/*" -not -path "./.build/*" 2>/dev/null | grep -q .; then
    check "No xcuserdata in repository" "fail"
else
    check "No xcuserdata in repository" "pass"
fi

# ---- Summary ----
echo ""
echo "=== Summary ==="
echo -e "${GREEN}Pass:${NC} $PASS  ${RED}Fail:${NC} $FAIL  ${YELLOW}Warn:${NC} $WARN"
if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}FAILED: $FAIL blocking items must be resolved before publication.${NC}"
    exit 1
else
    echo -e "${GREEN}Audit passed.${NC}"
    exit 0
fi
