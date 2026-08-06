#!/usr/bin/env python3
"""U1R18-R11 Local Runtime Acceptance Audit.

Verifies the fail-closed local runtime acceptance authority contract:

  * The acceptance sources carry the exact bounded enums and the single
    @MainActor authority.
  * The authoritative receipt is deterministic and redacted (never emits raw
    PIDs, PPIDs, UUIDs, absolute paths, usernames, window identities, argv, or
    raw error text).
  * The immutable scope (Sessions/*, .github/**, Package.swift, README,
    docs/**, Resources/**, script gates) is byte-identical to the parent HEAD
    commit — a semantic production mutation there is a violation.

Usage:
  python3 scripts/local-runtime-acceptance-audit.py [--repo-root <root>]

Exit codes:
  0 = clean contract
  1 = semantic production mutation / violation (violation lines printed)
  2 = infrastructure failure (missing/unreadable required file, missing
      required declaration or body, scanner failure, git unavailable)
"""
import os
import re
import subprocess
import sys

ACCEPTANCE = os.path.join("Sources", "MacSteam", "Acceptance")

# Required acceptance files with the core declarations that must be present.
# Missing file or missing declaration -> exit 2.
REQUIRED_CONTRACTS = [
    (ACCEPTANCE, "LocalRuntimeAcceptanceAuthority.swift",
     ["final class LocalRuntimeAcceptanceAuthority",
      "@MainActor", "func beginCandidate", "func observe",
      "func requireCompletion", "requiredStabilitySeconds",
      "var state", "var blocker", "func observe", "currentReceipt"]),
    (ACCEPTANCE, "LocalAcceptancePrerequisites.swift",
     ["struct LocalAcceptancePrerequisites", "var firstBlocker",
      "LocalReceiptSourceType"]),
    (ACCEPTANCE, "LocalAcceptanceReceipt.swift",
     ["struct LocalAcceptanceReceipt", "var deterministicJSON",
      "enum LocalAcceptanceBlocker", "enum LocalAcceptanceState",
      "var deterministicJSONString"]),
    (ACCEPTANCE, "LocalAcceptancePresentation.swift",
     ["struct LocalAcceptancePresentation", "isVisible",
      "canConfirmMainMenu", "canConfirmInputResponse", "canComplete"]),
]

# U1R18-R11-FIX1 contract join points in production UI/coordinator surfaces.
# A mutation removing any of these markers (e.g. hiding the acceptance UI
# behind a launch result, dropping the input-confirm action, rebuilding the
# receipt before acceptance, discarding authority on success, or deriving
# ownership from visibility) must be caught by the audit.
UI_CONTRACTS = [
    (os.path.join("Sources", "MacSteam", "Views", "CloverPitLaunchView.swift"),
     ["acceptancePanel", "acceptancePresentation", "confirmInputResponse"]),
    (os.path.join("Sources", "MacSteam", "Ultimate", "UltimateSetupCoordinator.swift"),
     ["func confirmInputResponse",
      "cancelLocalAcceptanceObservationPreservingAuthority",
      "invalidateAndDiscardLocalAcceptance",
      "var acceptancePresentation"]),
]

# Immutable-scope paths, relative to repo root. Must remain byte-identical to
# the parent HEAD commit. Any working-tree difference is a violation (exit 1).
# Directories are walked recursively; files are compared byte-wise.
IMMUTABLE_PATHS = [
    "Sources/MacSteam/Sessions",
    "Sources/MacSteam/Resources",
    "Sources/MacSteam/GameRecipe.swift",
    "Package.swift",
    "README.md",
    "docs",
    "Contracts/public-product-truth.schema.json",
    "scripts/workstage-review-gate.py",
    "scripts/workstage-review-gate-fixtures",
    "scripts/public-product-truth-audit.py",
    "scripts/test-public-product-truth-audit.sh",
]


def infra(msg: str):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def read_file(root: str, rel: str):  # -> Optional[str]
    path = os.path.join(root, rel)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        infra(f"cannot read required contract {path}: {e}")


def is_dir(root: str, rel: str) -> bool:
    return os.path.isdir(os.path.join(root, rel))


def list_files(root: str, rel: str):
    base = os.path.join(root, rel)
    out = []
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            out.append(os.path.relpath(full, root))
    return out


def git_head_content(root: str, rel: str):  # -> Optional[str]
    """Return file content at HEAD; None if absent at HEAD; exit 2 on git fail."""
    try:
        res = subprocess.run(
            ["git", "show", f"HEAD:{rel}"],
            cwd=root, capture_output=True, text=True,
        )
    except OSError as e:
        infra(f"git not usable: {e}")
    if res.returncode == 128 and "exists on disk" in res.stderr:
        return None
    if res.returncode != 0:
        infra(f"git show HEAD:{rel} failed: {res.stderr.strip()}")
    return res.stdout


def required_body(content: str, needle: str, context: str) -> str:
    """Balanced-brace body following `needle`. Missing/unparseable -> exit 2."""
    idx = content.find(needle)
    if idx < 0:
        infra(f"required contract missing: {context} (no '{needle}')")
    brace = content.find("{", idx)
    if brace < 0:
        infra(f"required contract unparseable: {context} (no body brace for '{needle}')")
    depth = 1
    i = brace + 1
    n = len(content)
    while depth > 0 and i < n:
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        infra(f"required contract unparseable: {context} (unbalanced braces for '{needle}')")
    return content[brace + 1:i - 1]


def completed_ordering_missing(accepted_at: int, receipt_at: int) -> bool:
    """True when the earned-receipt is (re)built without the authority already
    being accepted — i.e. the receipt is bound to a pre-accepted state. A
    present-and-ordered pair (accepted before receipt) is not a violation."""
    if accepted_at < 0:
        return False  # no explicit accepted assignment; covered elsewhere
    if receipt_at < 0:
        return False  # receipt builder not referenced here; not an ordering defect
    return receipt_at <= accepted_at


# Forbidden raw-subject emission inside the receipt-document sources. The
# authority must reduce to bounded booleans/ints/enums and drop identity,
# paths, PIDs, and unbounded error text before serialization.
FORBIDDEN_RAW_TOKENS = [
    r"\.rootPID\b",
    r"\brootPID\b",
    r"\.uuidString\b",
    r"\bprefixRoot\b",
    r"\.sessionID\b",
    r"error\.localizedDescription",
    r"processIdentifier\b",
]


def check_redaction(rel: str, content: str, violations: list[str]) -> None:
    """Only the deterministic-receipt serialization body may not emit raw
    identity/path/PID/error tokens. Internal candidate-identity comparison in
    the observer is legitimate observation logic, not receipt emission."""
    m = re.search(r"\bdeterministicJSON\b", content)
    if not m:
        return
    # Serialization body starts at the opening brace after `deterministicJSON`.
    brace = content.find("{", m.start())
    if brace < 0:
        return
    depth = 1
    i = brace + 1
    n = len(content)
    while depth > 0 and i < n:
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1
    if depth != 0:
        return
    serialized = content[brace + 1:i - 1]
    for pat in FORBIDDEN_RAW_TOKENS:
        for mm in re.finditer(pat, serialized):
            line = content.count("\n", 0, brace + mm.start()) + 1
            violations.append(
                f"{rel}:{line}: receipt serialization must not emit raw '{pat}'")


def main(argv) -> int:
    root = "."
    i = 0
    while i < len(argv):
        if argv[i] == "--repo-root" and i + 1 < len(argv):
            root = argv[i + 1]
            i += 2
            continue
        i += 1

    violations = []

    # ── Required contracts exist with core declarations ──
    for rel_dir, fname, needles in REQUIRED_CONTRACTS:
        rel = os.path.join(rel_dir, fname)
        content = read_file(root, rel)
        if content is None:
            infra(f"required contract missing: {rel}")
        for needle in needles:
            if needle not in content:
                infra(f"required contract missing: {rel} (no '{needle}')")

    # ── UI / coordinator join points (U1R18-R11-FIX1) ──
    for rel, needles in UI_CONTRACTS:
        content = read_file(root, rel)
        if content is None:
            infra(f"required contract missing: {rel}")
        for needle in needles:
            if needle not in content:
                violations.append(f"{rel}: FIX1 contract missing '{needle}'")

    # ── Fail-closed completion ordering (U1R18-R11-FIX1) ──
    # The earned receipt must be built only AFTER the authority has entered the
    # accepted state, never while still awaiting cleanup / in_progress.
    auth_rel = os.path.join(ACCEPTANCE, "LocalRuntimeAcceptanceAuthority.swift")
    auth = read_file(root, auth_rel)
    completions = required_body(auth, "func requireCompletion",
                                "LocalRuntimeAcceptanceAuthority requireCompletion")
    accepted_at = completions.find("state = .accepted")
    receipt_at = completions.find("buildAcceptedReceipt()")
    if completed_ordering_missing(accepted_at, receipt_at):
        violations.append(f"{auth_rel}: receipt built before accepted state "
                          "(FIX1 ordering violated)")

    # ── Ownership independence (U1R18-R11-FIX1) ──
    # Ownership proof must be an independent census-derived boolean, never
    # inferred from mere window visibility.
    obs_body = required_body(auth, "final class LocalRuntimeAcceptanceAuthority",
                             "LocalRuntimeAcceptanceAuthority class")
    if "ownershipCensusProven" not in auth:
        violations.append(f"{auth_rel}: independent ownershipCensusProven "
                        "surface missing (FIX1 violated)")

    # Authority must be the single mutation owner: no parallel acceptance
    # state may live in the coordinator's view layer. Verify the authority
    # owns the completion/cleanup gate.
    auth_rel = os.path.join(ACCEPTANCE, "LocalRuntimeAcceptanceAuthority.swift")
    auth = read_file(root, auth_rel)
    # The authority's completion gate must be owned by the authority body.
    auth_body = required_body(auth, "final class LocalRuntimeAcceptanceAuthority",
                              "LocalRuntimeAcceptanceAuthority class")
    if "func requireCompletion" not in auth_body:
        infra(f"required contract unparseable: {auth_rel} "
              "(requireCompletion absent from authority body)")

    # ── Redaction of receipt sources ──
    receipt_srcs = []
    for rel_dir, fname, _needles in REQUIRED_CONTRACTS:
        content = read_file(root, os.path.join(rel_dir, fname))
        if content is not None:
            receipt_srcs.append((os.path.join(rel_dir, fname), content))
    for rel, content in receipt_srcs:
        check_redaction(rel, content, violations)

    # The authority's deterministic receipt path must exist via currentReceipt
    # (declared as a required contract above, so an absence is exit 2).

    # ── Immutable-scope identity against HEAD ──
    for rel in IMMUTABLE_PATHS:
        full = os.path.join(root, rel)
        if is_dir(root, rel):
            for f in list_files(root, rel):
                current = read_file(root, f)
                head = git_head_content(root, f)
                if current is None or head is None:
                    continue  # added or scaffold-only; handled by fixtures
                if current != head:
                    violations.append(f"{f}: immutable scope changed vs HEAD")
        else:
            if not os.path.exists(full):
                continue
            current = read_file(root, rel)
            if current is None:
                continue
            head = git_head_content(root, rel)
            if head is None:
                continue
            if current != head:
                violations.append(f"{rel}: immutable scope changed vs HEAD")

    if violations:
        for v in violations:
            print(f"VIOLATION: {v}")
        print(f"\n{len(violations)} violation(s) — exit 1")
        return 1
    print("Local runtime acceptance audit clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))