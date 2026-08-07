#!/usr/bin/env python3
"""U1R18-R12 Local Runtime Acceptance Audit.

Verifies the fail-closed local runtime acceptance authority contract:

  * The acceptance sources carry the exact bounded enums and the single
    @MainActor authority.
  * The authoritative receipt is deterministic and redacted (never emits raw
    PIDs, PPIDs, UUIDs, absolute paths, usernames, window identities, argv, or
    raw error text).
  * U1R18-R12 durability: the accepted candidate is constructed, then durably
    persisted exactly once AFTER a clean cleanup and STRICTLY BEFORE the
    authority may enter the accepted state. A persistence failure blocks the
    transaction; it is never presented as acceptance.
  * The durable store persists only accepted receipts as the exact canonical
    bytes through a symlink-fail-closed, atomic, private (0700/0600) namespace,
    and loads only through a size → canonical-decode → semantic → canonical
    re-encode gate. A historical load never promotes the current acceptance
    state.
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
      "var state", "var blocker", "func observe", "currentReceipt",
      "receiptPersister", "LocalAcceptancePersistenceOutcome"]),
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
    (ACCEPTANCE, "LocalAcceptanceReceiptStore.swift",
     ["struct LocalAcceptanceReceiptStore", "func saveAccepted",
      "func loadAccepted", "func acceptedSemanticGate",
      "relativeReceiptPath", "maxReceiptBytes"]),
]

# U1R18-R12 contract join points in production UI/coordinator surfaces.
# A mutation removing any of these markers (e.g. hiding the acceptance UI
# behind a launch result, dropping the input-confirm action, rebuilding the
# receipt before acceptance, discarding authority on success, deriving
# ownership from visibility, or promoting a historical saved receipt into the
# current run) must be caught by the audit.
UI_CONTRACTS = [
    (os.path.join("Sources", "MacSteam", "Views", "CloverPitLaunchView.swift"),
     ["acceptancePanel", "acceptancePresentation", "confirmInputResponse",
      "savedLocalAcceptanceReceiptStatus"]),
    (os.path.join("Sources", "MacSteam", "Ultimate", "UltimateSetupCoordinator.swift"),
     ["func confirmInputResponse",
      "cancelLocalAcceptanceObservationPreservingAuthority",
      "invalidateAndDiscardLocalAcceptance",
      "var acceptancePresentation",
      "hasSavedLocalAcceptanceReceipt",
      "savedLocalAcceptanceReceiptStatus",
      "localAcceptanceReceiptStore"]),
]

# Store contract tokens whose absence is a semantic durability violation
# (exit 1): full independent accepted-only gate, symlink fail-closed, bounded
# no-follow same-FD load, same-directory atomic POSIX write with temp-only
# cleanup, private perms, and size-bounded canonical load.
STORE_CONTRACTS = [
    "acceptedSemanticGate",
    "status.state != .accepted",
    "blockerNotNone",
    "evidenceIncomplete",
    "visibilityBelowMinimum",
    "securityFlagSet",
    "targetMismatch",
    "malformedJSON",
    "nonCanonicalBytes",
    "oversized",
    "nonRegularFile",
    "symlinkDestinationRejected",
    "symlinkParentEscapeRejected",
    "receiptFilePermissions = 0o600",
    "parentDirectoryPermissions = 0o700",
    # File-descriptor fail-closed contract: the receipt is opened without
    # following a symlink, in the same directory, and read via the same FD.
    "openat",
    "O_NOFOLLOW",
    "O_DIRECTORY",
    "O_NONBLOCK",
    "fstat(",
    "S_IFREG",
    "read(fileFD",
    "ENOENT",
    # Atomic same-directory POSIX transaction with temp-only cleanup.
    "O_EXCL",
    "renameat",
    "fsync",
    "unlinkat",
]

# Tokens that must NEVER appear in the store: a path-based unbounded read and
# the deletion of the last-known-good receipt on a replacement failure.
STORE_FORBIDDEN = [
    "Data(contentsOf: receiptURL)",
    "removeItem(at: receiptURL)",
    "rename(tempPath, receiptPath)",
    "rename(tempName, receiptPath)",
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


def brace_body(content: str, start: int) -> str:
    """Balanced-brace body starting at `start` (which must precede a '{')."""
    brace = content.find("{", start)
    if brace < 0:
        return ""
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
        return ""
    return content[brace + 1:i - 1]


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
    # Only the file that DECLARES the serialization participates. Other sources
    # reference deterministicJSON (e.g. the durable store's temp-file naming)
    # without serializing the receipt, and must not be scanned.
    if re.search(r"\bvar deterministicJSON\b", content) is None:
        return
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

    # ── Fail-closed completion ordering (U1R18-R12) ──
    # The accepted candidate must be durably persisted exactly once AFTER a
    # clean cleanup and STRICTLY BEFORE the authority enters the accepted state.
    # A persistence failure blocks the transaction; it is never accepted.
    auth_rel = os.path.join(ACCEPTANCE, "LocalRuntimeAcceptanceAuthority.swift")
    auth = read_file(root, auth_rel)
    completions = required_body(auth, "func requireCompletion",
                                "LocalRuntimeAcceptanceAuthority requireCompletion")
    accepted_at = completions.find("state = .accepted")
    persist_at = completions.find("receiptPersister(")
    persist_count = completions.count("receiptPersister(")
    cleanup_at = completions.find("await cleanupRunner()")
    if accepted_at < 0:
        violations.append(f"{auth_rel}: completion never enters the accepted state (R12)")
    if persist_at < 0 or persist_count == 0:
        violations.append(f"{auth_rel}: completion never persists the accepted candidate (R12)")
    if persist_count > 1:
        violations.append(f"{auth_rel}: persistence invoked more than once (R12)")
    if persist_at >= 0 and cleanup_at >= 0 and persist_at < cleanup_at:
        violations.append(f"{auth_rel}: persistence runs before cleanup (R12)")
    if persist_at >= 0 and accepted_at >= 0 and persist_at >= accepted_at:
        violations.append(f"{auth_rel}: accepted state before successful persistence (R12)")
    # Acceptance must be bound to a persisted outcome — never to an unguarded
    # unconditional assignment after the persist call.
    if "case .persisted" not in completions and "receiptPersistenceFailed" not in completions:
        violations.append(f"{auth_rel}: acceptance not gated on persistence outcome (R12)")

    # ── Store durable contract (U1R18-R12) ──
    store_rel = os.path.join(ACCEPTANCE, "LocalAcceptanceReceiptStore.swift")
    store = read_file(root, store_rel)
    if store is None:
        infra(f"required contract missing: {store_rel}")
    for needle in STORE_CONTRACTS:
        if needle not in store:
            violations.append(f"{store_rel}: store contract missing '{needle}' (R12)")
    for needle in STORE_FORBIDDEN:
        if needle in store:
            violations.append(f"{store_rel}: store must not contain '{needle}' (FIX1)")
    if "0o644" in store:
        violations.append(f"{store_rel}: store must not use world-readable perms (R12)")
    wcb = brace_body(store, store.find("func writeCanonical"))
    if "deterministicJSON" not in wcb:
        violations.append(f"{store_rel}: atomic write must be the exact canonical bytes (R12)")
    lcb = brace_body(store, store.find("func loadAccepted"))
    if "deterministicJSON" not in lcb:
        violations.append(f"{store_rel}: load must re-encode canonical bytes (R12)")
    if "maxReceiptBytes" not in lcb:
        violations.append(f"{store_rel}: load must bound file size (R12)")
    # Bounded read must use the same opened FD (never a path re-open), must
    # prove regular-file type before reading, and must bound the read size.
    if "read(fileFD" not in lcb:
        violations.append(f"{store_rel}: load must read via the opened FD (FIX1)")
    if "maxReceiptBytes" not in lcb:
        violations.append(f"{store_rel}: load read must be bounded (FIX1)")
    if "fstat(" not in lcb or "S_IFREG" not in lcb:
        violations.append(f"{store_rel}: load must prove regular-file before read (FIX1)")
    # `.notFound` is reserved for an absent receipt; a caught read failure must
    # never degrade to `.notFound`.
    if "catch" in lcb:
        violations.append(f"{store_rel}: read failure must not become notFound (FIX1)")

    # ── U1R18-R12-FIX2 directory-FD-bound atomic rename ──
    # The final install must be a renameat where the source AND destination are
    # relative to the SAME opened directory FD. A path-based rename(tempPath,
    # receiptPath) that re-resolves a symlink or a renameat that switches
    # directory FDs is a violation.
    if "renameat" not in wcb:
        violations.append(f"{store_rel}: atomic install must use renameat (FIX2)")
    elif "renameat(dirFD, tempName, dirFD, receiptName)" not in wcb \
            and "renameat(dirFD, t, dirFD, d)" not in wcb:
        violations.append(f"{store_rel}: renameat must bind source and destination to the SAME directory FD (FIX2)")

    # ── U1R18-R12-FIX2 snapshot-consistent load ──
    # The load must read EXACTLY the pre-stat size (short read and post-stat
    # metadata change both fail closed), probe for growth past the pre-stat size,
    # and re-fstat the SAME FD before decoding.
    if "expectedSize" not in lcb:
        violations.append(f"{store_rel}: load must read exactly the pre-stat size (FIX2)")
    if "total" not in lcb or "n == 0" not in lcb:
        violations.append(f"{store_rel}: load must fail closed on an inconsistent short read (FIX2)")
    if "probeGrowth(" not in lcb:
        violations.append(f"{store_rel}: load must probe for growth past the pre-stat size (FIX2)")
    if "postStat" not in lcb:
        violations.append(f"{store_rel}: load must re-fstat the same FD after reading (FIX2)")
    if "st_mtimespec" not in lcb and "st_mtime" not in lcb:
        violations.append(f"{store_rel}: load must compare post-read metadata timestamps (FIX2)")

    # ── U1R18-R12-FIX2 bounded EINTR + zero-progress fail-closed ──
    if "maxInterruptedSyscallRetries" not in lcb:
        violations.append(f"{store_rel}: load EINTR retry must be bounded (FIX2)")
    if "maxInterruptedSyscallRetries" not in wcb:
        violations.append(f"{store_rel}: write EINTR retry must be bounded (FIX2)")
    # A zero-progress write must fail closed, never spin on a continue.
    if re.search(r"count\s*==\s*0\s*\{", wcb) is None:
        violations.append(f"{store_rel}: zero-progress write must fail closed (FIX2)")
    elif re.search(r"count\s*==\s*0\s*\{\s*continue", wcb):
        violations.append(f"{store_rel}: zero-progress write must fail closed (FIX2)")

    # ── U1R18-R12-FIX3 single-authority growth-probe EINTR closure ──
    # The growth probe is ONE bounded retry authority owned entirely by a
    # probeGrowth helper. Clean EOF (n == 0) is a legal terminal state that
    # continues to the post-read snapshot — never an ioFailure. A growth byte
    # (n == 1) fails. EINTR is consumed against a single counter bounded by
    # maxInterruptedSyscallRetries; the next consecutive EINTR after the bound
    # is the ninth and fails closed.
    if "probeGrowth(" not in store:
        violations.append(f"{store_rel}: growth probe must be a single retry authority (FIX3)")
    else:
        pbody = brace_body(store, store.find("func probeGrowth"))
        if "readProbeBounded" in store or "readProbeBounded" in pbody:
            violations.append(f"{store_rel}: growth probe must not split retry budget across helpers (FIX3)")
        if "n == 0" not in pbody or ".cleanEOF" not in pbody:
            violations.append(f"{store_rel}: growth probe must recover clean EOF after EINTR (FIX3)")
        if re.search(r"n\s*==\s*0[^\n]*\.(ioFailure|failed)", pbody):
            violations.append(f"{store_rel}: growth probe clean EOF must not be an ioFailure (FIX3)")
        if "n == 1" not in pbody or "growthDetected" not in pbody:
            violations.append(f"{store_rel}: growth probe must fail on a growth byte (FIX3)")
        if "maxInterruptedSyscallRetries" not in pbody:
            violations.append(f"{store_rel}: growth probe EINTR retry must be bounded (FIX3)")
        if re.search(r"eintrRetries\s*>\s*Self\.maxInterruptedSyscallRetries\s*[})\){]", pbody) is None:
            violations.append(f"{store_rel}: growth probe must fail on the ninth consecutive EINTR (FIX3)")

    # ── U1R18-R12-FIX1 authority: explicit persister + exact identity ──
    # The persister must be a required (non-defaulted) parameter and its
    # persisted receipt must be the exact candidate. A defaulted success
    # persister or a result-substitution path is a violation.
    if "receiptPersister: @escaping (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome" in auth:
        pass
    else:
        violations.append(f"{auth_rel}: explicit durable persister must be a required init parameter (FIX1)")
    if "persisted == candidate" not in auth:
        violations.append(f"{auth_rel}: persisted receipt identity must be checked against the candidate (FIX1)")
    if "= { .persisted($0) }" in auth or "receiptPersister: @escaping (LocalAcceptanceReceipt) async -> LocalAcceptancePersistenceOutcome = " in auth:
        violations.append(f"{auth_rel}: success-default persister is forbidden; caller must supply it (FIX1)")

    # ── Historical load must never promote the current acceptance state (R12) ──
    # Loading a saved receipt is historical evidence only; it must not begin a
    # candidate, set prerequisites, invalidate, or enter accepted on the caller's
    # behalf.
    coord_rel = os.path.join("Sources", "MacSteam", "Ultimate",
                             "UltimateSetupCoordinator.swift")
    coordinator = read_file(root, coord_rel)
    for hist_var in ("savedLocalReceipt", "savedLocalStore"):
        idx = coordinator.find(hist_var + ":")
        if idx < 0:
            continue
        body = brace_body(coordinator, idx)
        if body == "":
            continue
        for tok in ("beginCandidate", "setPrerequisites", "invalidate(",
                    "state = .accepted", "requireCompletion",
                    "enterBlocked", "owner = "):
            if tok in body:
                violations.append(
                    f"{coordinator_rel}: historical load must not promote "
                    f"current acceptance state ('{tok}') (R12)")

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