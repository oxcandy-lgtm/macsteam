#!/usr/bin/env python3
"""MacsTeam public product truth audit (stdlib only).

Read-only, fail-closed tooling that verifies that the public-facing product
documentation (README.md + public docs) describe the product that actually
exists at the repository HEAD, as encoded in the machine-readable authority
at docs/public-product-truth.json against the schema at
Contracts/public-product-truth.schema.json.

Guards (20, all reachable):
  Content / policy guards (exit 1):
    public_truth_schema_invalid           - authority violates schema, OR
                                             the schema itself is weakened
    public_truth_semantic_invalid         - authority violates independent
                                             semantic contract
    public_truth_marker_missing           - README marker missing / misplaced
    public_truth_marker_duplicated
    public_truth_branding_invalid
    public_truth_runtime_invalid
    public_truth_steam_invalid
    public_truth_acceptance_overclaim
    public_truth_packaging_overclaim
    public_truth_release_overclaim
    public_truth_r5_invalid
    public_truth_stale_crossover_prerequisite
    public_truth_stale_wine_claim
    public_truth_docs_drift               - designated doc missing / drifted
                                            from a positive binding
    public_truth_roadmap_invalid
  Infrastructure guards (exit 2):
    public_truth_schema_io_error
    public_truth_schema_parse_error
    public_truth_authority_io_error
    public_truth_authority_parse_error
    public_truth_readme_io_error

Commands:
  audit --root <repo-root>

Exit codes:
  1: content / policy violation
  2: filesystem / parse / infrastructure failure
"""

import argparse
import json
import os
import re
import sys

EMPTY = ""

EXIT_POLICY = 1
EXIT_INFRA = 2

MARKER = "<!-- macsteam-public-product-truth:v1 -->"
R5_SENTENCE = (
    "R5 external real-Mac proof requirement was removed by product-owner "
    "decision. No external proof was performed or claimed."
)

# Designated canonical public docs that must agree with the authority.  Every
# file here is mandatory: a missing file is a docs-drift failure (fail closed,
# no "continue on missing").
CANONICAL_DOCS = [
    "docs/ARCHITECTURE.md",
    "docs/CLOVERPIT_U1.md",
    "docs/DISTRIBUTION_BOUNDARIES.md",
    "docs/GAME_RECIPE_CONTRACT.md",
    "docs/PREFIX_LIFECYCLE.md",
    "docs/RUNTIME_CONTRACT.md",
    "docs/SECURITY_BOUNDARIES.md",
    "docs/STEAM_BOUNDARY.md",
    "docs/ULTIMATE_ARCHITECTURE.md",
]

# The 9 README L2 sections that are the source of truth for product claims.
# Each must appear exactly once.  Extra sections (Build/Run/Test/Contributing/
# License/...) are permitted, but these 9 are mandatory and must not duplicate.
REQUIRED_README_SECTIONS = [
    "Current Status",
    "Runtime Truth",
    "Setup Flow",
    "How It Works",
    "Distribution Truth",
    "Safety and Privacy",
    "Known Limitations",
    "Completion Roadmap",
    "R5 Note",
]

# §7.1 Current Status - facts the owning section must carry on visible prose.
CURRENT_STATUS_FACTS = [
    (r"macOS\s*15\.0", "macOS 15.0+"),
    (r"Apple Silicon", "Apple Silicon"),
    (r"Swift Package", "Swift Package build"),
    (r"3314790", "CloverPit Steam App ID"),
    (r"Implemented", "CloverPit implemented"),
    (r"acceptance\s*(Enhanced )?\|\s*Pending|acceptance\s*pending", "local acceptance pending"),
    # §4.2: app-availability truth must be bound to the signed/notarized
    # downloadable app. A generic "not yet available" attached to another
    # feature must not satisfy it.
    (r"(?:downloadable|signed|notarized)[^\n]*app[^\n]*not yet available"
     r"|not yet available[^\n]*downloadable", "downloadable app unavailable"),
]

# §7.2 Runtime Truth - all conditions, in-section only AND bound to their
# subject. Each tuple is (subject_pattern, fact_pattern, label): a generic
# phrase ("not required"/"not canonical"/"future") that is NOT attached to its
# intended subject (e.g. attached to Imported Wine, system Wine, another
# adapter, or unrelated prose) must not satisfy the fact. A fact is present
# only when SOME statement in the section carries both the subject and the fact.
RUNTIME_TRUTH_FACTS = [
    ("imported wine", r"canonical", "Imported Wine canonical"),
    ("system wine", r"may be discovered|discovered", "System Wine discoverable"),
    ("system wine", r"excluded from the default|not[^\n]*(selected )?by default",
     "System Wine not default"),
    ("managed wine", r"future|unavailable", "Managed Wine unavailable"),
    ("cross[Oo]ver", r"not required", "CrossOver not required"),
    ("cross[Oo]ver", r"not canonical", "CrossOver not canonical"),
    ("cross[Oo]ver", r"disabled[- ]by[- ]default|not default[- ]enabled",
     "CrossOver disabled by default"),
    ("cross[Oo]ver", r"explicit opt[- ]in", "CrossOver explicit opt-in"),
    ("cross[Oo]ver", r"lowest[- ]priority", "CrossOver lowest priority"),
    ("cross[Oo]ver", r"never a prerequisite|not a prerequisite",
     "CrossOver never prerequisite"),
]

# §7.3 Setup Flow - ordered coordinator steps (positions must increase).
SETUP_FLOW_ORDER = [
    r"select/import a runtime",
    r"inspect/create a canonical wine prefix",
    r"select a user[- ]obtained steam installer|user-selected steam installer",
    r"install/open steam",
    r"detect/install/launch cloverpit",
]

# §7.4 How It Works - visible prose only (fenced diagram alone fails).
# §4.3: runtime resolution must bind to the imported / user-selected Wine
# runtime. Generic "runtime detection" prose without that binding must fail.
HOW_IT_WORKS_FACTS = [
    (r"recipe loading", "recipe loading"),
    (r"(?:imported|user[-]?selected)[^\n]*runtime"
     r"|runtime[^\n]*(?:detection|selection)[^\n]{0,60}(?:imported|user[-]?selected)",
     "runtime resolution bound to imported/user-selected Wine"),
    (r"windows steam", "Windows Steam detection"),
    (r"game inspection", "game installation inspection"),
    (r"app id", "game launch with app ID"),
]

# §7.5 Distribution Truth - packaging facts, in-section only.
DISTRIBUTION_TRUTH_FACTS = [
    (r"swift package development execution", "Swift Package development execution"),
    (r"\.app.*bundle.*not complete|no \.app bundle", "no completed .app bundle"),
    (r"codesign[^\n]*not complete|codesign.*incomplete", "codesign incomplete"),
    (r"notariz[^\n]*not complete|notariz.*incomplete", "notarization incomplete"),
    (r"packaging[^\n]*not complete|packaging.*incomplete", "packaging incomplete"),
    (r"no release download", "no release download advertised"),
]

# §7.6 Safety and Privacy - privacy facts, in-section only.
SAFETY_PRIVACY_FACTS = [
    (r"no steam installer bundling", "no installer bundling"),
    (r"no app-controlled steam installer download", "no app-controlled download"),
    (r"no steam credential access", "no credential access"),
    (r"no sudo", "no sudo"),
    (r"no shell command construction|no shell", "no shell command construction"),
    (r"diagnostics[^\n]*local", "diagnostics local"),
    (r"redacted", "diagnostics redacted"),
]

# §7.7 Known Limitations - limitation facts, in-section only.
KNOWN_LIMITATIONS_FACTS = [
    (r"steam rendering[^\n]*acceptance[^\n]*pending|steam rendering.*pending",
     "Steam rendering pending"),
    (r"cloverpit gameplay[^\n]*acceptance[^\n]*pending|cloverpit gameplay.*pending",
     "CloverPit gameplay pending"),
    (r"no performance", "no performance claim"),
    (r"no[^\n]*audio", "no audio claim"),
    (r"no[^\n]*input", "no input claim"),
    (r"no clean-install", "no clean-install claim"),
    (r"no[^\n]*gatekeeper", "no Gatekeeper claim"),
    (r"only cloverpit", "CloverPit only current target"),
    # §4.4: each limitation fact is independent - removal of ANY one of them
    # fails even when the other two remain present (no OR pattern).
    (r"no game[^\n]*metadata|no[^\n]{0,60}metadata display", "no game metadata display"),
    (r"no[^\n]{0,90}save management|save management[^\n]*(not|yet)",
     "no save management"),
    (r"no[^\n]{0,90}cloud sync|cloud sync[^\n]*(not|yet)", "no cloud sync"),
]

# §7.8 Completion Roadmap - ordered lanes.  Each lane lists the ordered steps;
# both lanes must appear in order inside the owning section.
MINIMAL_LANE_ORDER = [
    r"public truth",
    r"local runtime acceptance",
    r"final audit",
    r"ready",
    r"merge",
]
GENERAL_LANE_ORDER = [
    r"public truth",
    r"\.app build",
    r"signing",
    r"notariz",
    r"packaging",
    r"local runtime acceptance",
    r"clean-install",
    r"gatekeeper acceptance",
    r"final audit",
    r"ready",
    r"merge",
    r"release",
]

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def die(guard, exit_code, message):
    payload = {"guard": guard, "exit": exit_code, "message": message}
    print(json.dumps(payload), file=sys.stderr)
    sys.exit(exit_code)


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", newline="") as fh:
            return fh.read()
    except OSError as exc:
        die("file_io_error", EXIT_INFRA, f"cannot read {path}: {exc}")


def read_text_guard(path, guard):
    try:
        with open(path, "r", encoding="utf-8", newline="") as fh:
            return fh.read()
    except OSError as exc:
        die(guard, EXIT_INFRA, f"cannot read {path}: {exc}")


def read_json(path, guard_io, guard_parse):
    text = read_text_guard(path, guard_io)
    try:
        return json.loads(text)
    except ValueError as exc:
        die(guard_parse, EXIT_INFRA, f"{path} is not valid JSON: {exc}")


# --------------------------------------------------------------------------
# JSON Schema validator (draft-07 subset used by the product truth schema)
# --------------------------------------------------------------------------

def _type_matches(instance, type_name):
    if type_name == "object":
        return isinstance(instance, dict)
    if type_name == "array":
        return isinstance(instance, list)
    if type_name == "string":
        return isinstance(instance, str)
    if type_name == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if type_name == "boolean":
        return isinstance(instance, bool)
    if type_name == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    if type_name == "null":
        return instance is None
    return False


def _validate(instance, schema, path):
    if not isinstance(schema, dict):
        return None
    type_name = schema.get("type")
    if type_name is not None and not _type_matches(instance, type_name):
        return f"{path}: expected type {type_name!r}, got {type(instance).__name__}"
    if "const" in schema and instance != schema["const"]:
        return f"{path}: expected const {schema['const']!r}, got {instance!r}"
    if "enum" in schema and instance not in schema["enum"]:
        return f"{path}: value {instance!r} not in enum"
    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                return f"{path}: missing required property {req!r}"
        properties = schema.get("properties", {})
        for key, sub in properties.items():
            if key in instance:
                err = _validate(instance[key], sub, f"{path}.{key}")
                if err:
                    return err
        if schema.get("additionalProperties") is False:
            allowed = set(properties)
            for key in instance:
                if key not in allowed:
                    return f"{path}: additional property {key!r} not allowed"
    return None


# --------------------------------------------------------------------------
# schema self-contract (§5) — the schema must NOT be weakened.
# --------------------------------------------------------------------------
# The audit independently verifies that the schema keeps the binding it claims:
# a valid-but-weakened schema (const removed/widened, additionalProperties
# widened to allow extra keys, required fields dropped, schema_version/kind or
# the runtime/packaging/release/R5 value consts removed) is a schema_invalid
# failure even though it would not fail a "validate instance against weakened
# schema" pass.

SCHEMA_DRAFT_07 = "http://json-schema.org/draft-07/schema#"

# Each prop is (expected_const, expected_native_type, expected_declared_type).
# expected_declared_type is the JSON "type" the reference schema declares for
# that property, or None when the reference schema does not declare a "type"
# (only schema_version/kind at the top level).  When it is not None, the schema
# must keep that exact declared type (no removal / widening).  The native type
# of the const is always enforced so a plain "const" binding cannot be stripped.
SCHEMA_CONTRACT_TOP = {
    "type": "object",
    "required": ["schema_version", "kind", "branding", "platform", "runtime",
                 "steam", "cloverpit", "packaging", "release", "r5"],
    "props": {
        "schema_version": (1, "integer", None),
        "kind": ("macsteam_public_product_truth", "string", None),
    },
}


def _require_value(prop, expected_const, expected_native, expected_declared):
    """Return None if prop keeps an exact native-typed const == expected_const,
    keeps the required JSON const binding, and (when the reference schema
    declares a type for this property) keeps that exact declared type.  Exact
    identity matters: booleans never accept 0/1/"false"/"true", and a declared
    type cannot be dropped or widened."""
    if not isinstance(prop, dict):
        return f"property block not an object: {prop!r}"
    if "const" not in prop:
        return f"const removed (expected {expected_const!r})"
    const = prop.get("const")
    if const != expected_const:
        return f"const removed or changed (expected {expected_const!r}, got {const!r})"
    # native type identity for the const value
    if expected_native == "boolean" and not isinstance(const, bool):
        return f"boolean const is not a native boolean: {const!r}"
    if expected_native == "integer" and (not isinstance(const, int) or isinstance(const, bool)):
        return f"integer const is not a native integer: {const!r}"
    if expected_native == "string" and not isinstance(const, str):
        return f"string const is not a native string: {const!r}"
    # when the reference schema declares a type for this property, it must stay
    if expected_declared is not None:
        declared = prop.get("type")
        if declared != expected_declared:
            return f"type removed or changed (expected {expected_declared!r}, got {declared!r})"
    return None


def _require_closed(obj, required, props, expected_type):
    """Return None if obj keeps type, required set, additionalProperties:false,
    and every key in props is present with exact const+type.  props is
    {key: (expected_const, expected_native, expected_declared)}."""
    if obj.get("type") != expected_type:
        return f"type is not {expected_type!r}: {obj.get('type')!r}"
    actual_required = obj.get("required")
    if not isinstance(actual_required, list):
        return "required is not an array"
    if set(required) - set(actual_required):
        return f"required subset dropped: {sorted(set(required) - set(actual_required))}"
    if obj.get("additionalProperties") is not False:
        return "additionalProperties is not false"
    properties = obj.get("properties")
    if not isinstance(properties, dict):
        return "properties is not an object"
    for key, (expected_const, expected_native, expected_declared) in props.items():
        if key not in properties:
            return f"property {key!r} removed"
        err = _require_value(properties[key], expected_const, expected_native, expected_declared)
        if err:
            return f"{key}: {err}"
    return None


def schema_contract_violation(schema):
    """Return a human-readable violation if the schema is weakened, else None."""
    if not isinstance(schema, dict):
        return "schema root is not an object"
    if schema.get("$schema") != SCHEMA_DRAFT_07:
        return f"schema draft id removed or changed: {schema.get('$schema')!r}"
    top_err = _require_closed(schema, SCHEMA_CONTRACT_TOP["required"],
                              SCHEMA_CONTRACT_TOP["props"],
                              SCHEMA_CONTRACT_TOP["type"])
    if top_err:
        return f"top-level: {top_err}"
    properties = schema.get("properties", {})
    for key, contract in SCHEMA_CONTRACT_SECTIONS.items():
        if key not in properties:
            return f"section {key!r} removed from schema"
        err = _require_closed(properties[key], contract["required"], contract["props"],
                              contract["type"])
        if err:
            return f"section {key!r}: {err}"
    return None

SCHEMA_CONTRACT_SECTIONS = {
    "branding": {
        "type": "object",
        "required": ["product_display_name", "internal_module_name"],
        "props": {"product_display_name": ("MacsTeam", "string", "string"),
                  "internal_module_name": ("MacSteam", "string", "string")},
    },
    "platform": {
        "type": "object",
        "required": ["operating_system", "minimum_version", "architecture"],
        "props": {"operating_system": ("macOS", "string", "string"),
                  "minimum_version": ("15.0", "string", "string"),
                  "architecture": ("Apple Silicon", "string", "string")},
    },
    "runtime": {
        "type": "object",
        "required": ["canonical_u1_runtime", "system_wine_discoverable",
                     "system_wine_selected_by_default", "managed_wine_available",
                     "crossover_canonical", "crossover_required",
                     "crossover_default_enabled", "crossover_policy"],
        "props": {
            "canonical_u1_runtime": ("imported-wine", "string", "string"),
            "system_wine_discoverable": (True, "boolean", "boolean"),
            "system_wine_selected_by_default": (False, "boolean", "boolean"),
            "managed_wine_available": (False, "boolean", "boolean"),
            "crossover_canonical": (False, "boolean", "boolean"),
            "crossover_required": (False, "boolean", "boolean"),
            "crossover_default_enabled": (False, "boolean", "boolean"),
            "crossover_policy": ("disabled-by-default-explicit-opt-in-lowest-priority", "string", "string"),
        },
    },
    "steam": {
        "type": "object",
        "required": ["installer_mode", "installer_bundled",
                     "installer_downloaded_by_app", "credentials_accessed"],
        "props": {"installer_mode": ("user-selected-file", "string", "string"),
                  "installer_bundled": (False, "boolean", "boolean"),
                  "installer_downloaded_by_app": (False, "boolean", "boolean"),
                  "credentials_accessed": (False, "boolean", "boolean")},
    },
    "cloverpit": {
        "type": "object",
        "required": ["steam_app_id", "implementation_status",
                     "playability_claimed"],
        "props": {"steam_app_id": ("3314790", "string", "string"),
                  "implementation_status": ("implemented-pending-local-acceptance", "string", "string"),
                  "playability_claimed": (False, "boolean", "boolean")},
    },
    "packaging": {
        "type": "object",
        "required": ["current_distribution", "app_bundle_available",
                     "codesigned", "notarized", "packaged_release_available"],
        "props": {"current_distribution": ("swift-package-development-build", "string", "string"),
                  "app_bundle_available": (False, "boolean", "boolean"),
                  "codesigned": (False, "boolean", "boolean"),
                  "notarized": (False, "boolean", "boolean"),
                  "packaged_release_available": (False, "boolean", "boolean")},
    },
    "release": {
        "type": "object",
        "required": ["pull_request_draft", "ready_authorized",
                     "merge_authorized", "release_authorized"],
        "props": {"pull_request_draft": (True, "boolean", "boolean"),
                  "ready_authorized": (False, "boolean", "boolean"),
                  "merge_authorized": (False, "boolean", "boolean"),
                  "release_authorized": (False, "boolean", "boolean")},
    },
    "r5": {
        "type": "object",
        "required": ["external_real_mac_proof_requirement_removed",
                     "external_real_mac_proof_performed",
                     "external_real_mac_proof_claimed"],
        "props": {"external_real_mac_proof_requirement_removed": (True, "boolean", "boolean"),
                  "external_real_mac_proof_performed": (False, "boolean", "boolean"),
                  "external_real_mac_proof_claimed": (False, "boolean", "boolean")},
    },
}


# --------------------------------------------------------------------------
# product truth authority validation
# --------------------------------------------------------------------------

# Independent semantic contract: every fixed authority value, checked against
# the manifest WITHOUT trusting the schema's const/type/required.  Each entry
# is (section, key, expected_value, expected_py_type).  Exact type identity is
# enforced for booleans so 0 / 1 / "false" / "true" are never accepted as bool.
SEMANTIC_FIXED = [
    # branding
    ("branding", "product_display_name", "MacsTeam", str),
    ("branding", "internal_module_name", "MacSteam", str),
    # platform
    ("platform", "operating_system", "macOS", str),
    ("platform", "minimum_version", "15.0", str),
    ("platform", "architecture", "Apple Silicon", str),
    # runtime
    ("runtime", "canonical_u1_runtime", "imported-wine", str),
    ("runtime", "system_wine_discoverable", True, bool),
    ("runtime", "system_wine_selected_by_default", False, bool),
    ("runtime", "managed_wine_available", False, bool),
    ("runtime", "crossover_canonical", False, bool),
    ("runtime", "crossover_required", False, bool),
    ("runtime", "crossover_default_enabled", False, bool),
    ("runtime", "crossover_policy",
     "disabled-by-default-explicit-opt-in-lowest-priority", str),
    # steam
    ("steam", "installer_mode", "user-selected-file", str),
    ("steam", "installer_bundled", False, bool),
    ("steam", "installer_downloaded_by_app", False, bool),
    ("steam", "credentials_accessed", False, bool),
    # cloverpit
    ("cloverpit", "steam_app_id", "3314790", str),
    ("cloverpit", "implementation_status",
     "implemented-pending-local-acceptance", str),
    ("cloverpit", "playability_claimed", False, bool),
    # packaging
    ("packaging", "current_distribution", "swift-package-development-build", str),
    ("packaging", "app_bundle_available", False, bool),
    ("packaging", "codesigned", False, bool),
    ("packaging", "notarized", False, bool),
    ("packaging", "packaged_release_available", False, bool),
    # release
    ("release", "pull_request_draft", True, bool),
    ("release", "ready_authorized", False, bool),
    ("release", "merge_authorized", False, bool),
    ("release", "release_authorized", False, bool),
    # r5
    ("r5", "external_real_mac_proof_requirement_removed", True, bool),
    ("r5", "external_real_mac_proof_performed", False, bool),
    ("r5", "external_real_mac_proof_claimed", False, bool),
]


SEMANTIC_INVALID = "public_truth_semantic_invalid"
_semantic_detail = None


def semantic_validate(truth):
    global _semantic_detail
    _semantic_detail = None
    if not isinstance(truth, dict):
        _semantic_detail = "authority root is not an object"
        return SEMANTIC_INVALID
    for section, key, expected, py_type in SEMANTIC_FIXED:
        node = truth.get(section) if isinstance(truth, dict) else None
        if not isinstance(node, dict) or key not in node:
            _semantic_detail = f"{section}.{key} is missing"
            return SEMANTIC_INVALID
        value = node[key]
        # exact type identity first (reject 0/1/"false"/"true" as bool)
        if not isinstance(value, py_type):
            _semantic_detail = (f"{section}.{key} has wrong type: "
                                f"{value!r} ({type(value).__name__})")
            return SEMANTIC_INVALID
        if value != expected:
            _semantic_detail = (f"{section}.{key} expected {expected!r}, "
                                f"got {value!r}")
            return SEMANTIC_INVALID
    return None


# --------------------------------------------------------------------------
# markdown helpers
# --------------------------------------------------------------------------

def strip_html_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def strip_fenced_blocks(text):
    """Remove fenced code blocks (``` or ~~~ fences, with or without a
    language tag).  Content inside a fence is invisible evidence: headings,
    correct answer words, and claims inside a fence must never satisfy a
    check on visible prose."""
    out = []
    in_fence = None
    for line in text.splitlines():
        m = re.match(r"^\s*((?:`{3,})|(?:~{3,}))\s*(.*)$", line)
        if m:
            marker = m.group(1)
            char = marker[0]
            if in_fence is None:
                in_fence = char
            elif in_fence == char:
                in_fence = None
            out.append("")
            continue
        if in_fence is not None:
            out.append("")
            continue
        out.append(line)
    return "\n".join(out)


def sanitize_markdown(text):
    """Visible prose for evidence checks: HTML comments and fenced code blocks
    are removed so comment/fence decoys cannot satisfy positive bindings."""
    return strip_fenced_blocks(strip_html_comments(text))


def _heading_body_span(text, headings, h):
    """(start, end) raw character offsets spanning heading h's body: from the
    end of h up to the next heading of level <= h.level, else EOF."""
    end = len(text)
    for nxt in headings:
        if nxt.start > h.start and nxt.level <= h.level:
            end = nxt.start
            break
    return h.end, end


def _heading_body(text, headings, h):
    """Sanitized visible prose body of one heading: comments and fenced blocks
    in the span are stripped so a decoy inside them cannot satisfy a binding.
    Nested subsections fold into their owning level-2 body naturally."""
    start, end = _heading_body_span(text, headings, h)
    return sanitize_markdown(text[start:end]).strip()


def l2_inventory(text):
    """Ordered list of (title, body) for every VISIBLE level-2 Markdown
    heading (ATX or Setext), never collapsed by title. raw-HTML <h2> headings
    are NOT adopted as sections (they must be rejected before this point).

    The list is never collapsed by title and occurrences are never trusted by
    "first/last match wins": the caller enforces the exactly-once requirement,
    so exact duplicates (even when every duplicate carries the accepted
    bindings) are always counted. Each body is the sanitized visible prose of
    the owner span, so a fact hidden in a comment or fenced block cannot
    satisfy a binding.
    """
    headings, _html, _unclosed = parse_headings(text)
    return [(h.title, _heading_body(text, headings, h))
            for h in headings if h.level == 2]


def dedent(text):
    return re.sub(r"[ \t]+", " ", text).replace(" ", "")


def _statements(sec):
    """Split a section into logical statements.

    A statement is one bullet (a line starting with a list marker) together
    with its wrapped continuation lines, or a bare paragraph. Subject-bound
    fact checks operate on these statements so a fact is only satisfied when
    its subject appears in the same statement as the fact phrase.
    """
    stmts = []
    cur = None
    for line in sec.splitlines():
        if re.match(r"^\s*[-*]\s+", line):
            if cur is not None:
                stmts.append(" ".join(cur))
            cur = [line]
        elif line.strip():
            if cur is not None:
                cur.append(line)
            else:
                stmts.append(line)
        else:
            if cur is not None:
                stmts.append(" ".join(cur))
                cur = None
    if cur is not None:
        stmts.append(" ".join(cur))
    return stmts


SETEXT_H1_RE = re.compile(r"^[ \t]{0,3}=+[ \t]*$")
SETEXT_H2_RE = re.compile(r"^[ \t]{0,3}-+[ \t]*$")
ATX_HEADING_RE = re.compile(r"^( {0,3})(#{1,6})(?:[ \t]+(.*))?[ \t]*$")
FENCE_RE = re.compile(r"^[ \t]{0,3}((?:`{3,})|(?:~{3,}))")
HTML_H_RE = re.compile(r"<(?!\s*/)\s*h([12])\b[^>]*>", re.IGNORECASE)
HTML_H_PAIR_RE = re.compile(r"<(?!\s*/)\s*h([12])\b[^>]*>(.*?)</\s*h\1\s*>",
                            re.IGNORECASE | re.DOTALL)


class _Heading:
    __slots__ = ("level", "title", "syntax", "start", "end")

    def __init__(self, level, title, syntax, start, end):
        self.level = level
        self.title = title
        self.syntax = syntax
        self.start = start
        self.end = end


def _is_setext_title(line):
    """A visible text line is a setext title unless blank, 4+-indented code,
    or itself an underline."""
    if not line.strip():
        return False
    if re.match(r"^[ \t]{4,}", line):
        return False
    if SETEXT_H1_RE.match(line) or SETEXT_H2_RE.match(line):
        return False
    return True


def _visible_lines(text):
    """Per-line (start_offset, raw, no_eol_line, visible). A line is invisible
    inside a fenced code block, an HTML comment, or 4-space-indented code; an
    unclosed fence or comment keeps everything after it invisible (fail closed,
    never exposing a hidden heading as visible). `visible` only governs heading
    DETECTION — body prose is sliced from raw offsets, so invisibility here
    never strips content."""
    lines = []
    offset = 0
    in_fence = None
    in_comment = False
    for raw in text.splitlines(keepends=True):
        line = raw.rstrip("\r\n")
        if in_comment:
            visible = False
            if "-->" in line:
                in_comment = False
        elif in_fence is not None:
            visible = False
            fm = FENCE_RE.match(line)
            if fm and fm.group(1)[0] == in_fence:
                in_fence = None
        elif "<!--" in line:
            visible = False
            in_comment = "-->" not in line.split("<!--", 1)[1]
        else:
            fm = FENCE_RE.match(line)
            if fm:
                visible = False
                in_fence = fm.group(1)[0]
            elif re.match(r"[ \t]{4,}", line):
                # 4-space-indented code: never a heading, never an HTML
                # heading violation (content still reaches body spans).
                visible = False
            else:
                visible = True
        lines.append((offset, raw, line, visible))
        offset += len(raw)
    return lines, (in_fence is not None or in_comment)


def parse_headings(text):
    """Return (headings, html, unclosed).

    headings: ordered, never-collapsed list of _Heading for every VISIBLE
    Markdown heading (ATX or Setext), with raw offsets. Setext records span
    title + underline; their body starts at the underline's next line.

    html: ordered _Heading records (syntax="html") for every VISIBLE raw-HTML
    <h1>/<h2> heading tag. raw-HTML headings are NOT adopted as section
    authority: the caller must fail closed on them per document type.

    Fenced-code lines, HTML comments, and 4-space-indented code are invisible:
    a `# Fake H1` or `<h2>Fake</h2>` inside them can never supply the product
    H1, a required section, or a marker-placement boundary. Titles are exact
    parsed text (trailing ATX hashes stripped, edges trimmed) with NO Markdown
    emphasis stripping, so a misprinted or emphasized product name is never
    masked.
    """
    lines, unclosed = _visible_lines(text)
    headings = []
    html = []
    n = len(lines)
    i = 0
    while i < n:
        start, raw, line, vis = lines[i]
        if not vis:
            i += 1
            continue
        am = ATX_HEADING_RE.match(line)
        if am:
            level = len(am.group(2))
            title = re.sub(r"[ \t]+#+[ \t]*$", "", (am.group(3) or "")).strip()
            headings.append(_Heading(level, title, "atx", start, start + len(raw)))
            i += 1
            continue
        hm = HTML_H_RE.search(line)
        if hm:
            level = int(hm.group(1))
            pair = HTML_H_PAIR_RE.search(line)
            title = pair.group(2).strip() if pair else ""
            html.append(_Heading(level, title, "html", start, start + len(raw)))
            i += 1
            continue
        # Setext: this visible line is a title when the next line is an
        # underline. A blank, indented-code, or underline line is not a title.
        if i + 1 < n and lines[i + 1][3]:
            nxt = lines[i + 1]
            su = SETEXT_H1_RE.match(nxt[2]) or SETEXT_H2_RE.match(nxt[2])
            if su and _is_setext_title(line):
                level = 1 if su.group(0).lstrip().startswith("=") else 2
                headings.append(_Heading(
                    level, line.strip(), "setext",
                    start, nxt[0] + len(nxt[1])))
                i += 2
                continue
        i += 1
    return headings, html, unclosed


# Stale / overclaiming statement patterns mapped to their guards.  Each match
# is window-negated by default (a "not/no/never/..." within a small window of
# the match is treated as a negation, not an overclaim).  Patterns whose claim
# is *inherently* a negation are marked negatable=False.
STALE_PATTERNS = [
    (r"initial runtime[^\n]*crossover", "public_truth_stale_crossover_prerequisite"),
    (r"\bcrossover\b[^\n]*\b(prerequisite|canonical-u1|initial runtime)\b",
     "public_truth_stale_crossover_prerequisite"),
    (r"\bcrossover\b[^\n]*\b(required|must be installed)\b",
     "public_truth_stale_crossover_prerequisite"),
    (r"\brequires?\s+((a |the )?crossover)\b", "public_truth_stale_crossover_prerequisite"),
    (r"\byou (need|must|have to) install crossover\b", "public_truth_stale_crossover_prerequisite"),
    (r"\b(no|without) wine support\b", "public_truth_stale_wine_claim", False),
    (r"system wine[^\n]*(selected by default|default runtime)", "public_truth_runtime_invalid"),
    (r"managed wine[^\n]*\b(available|included)\b", "public_truth_runtime_invalid"),
    (r"steam installer[^\n]*\b(bundled|downloaded)\b", "public_truth_steam_invalid"),
    (r"installer (is )?bundled with (the )?app\b", "public_truth_steam_invalid"),
    (r"\bproven playable\b", "public_truth_acceptance_overclaim"),
    (r"\bplayable\b", "public_truth_acceptance_overclaim"),
    (r"\bFPS\b", "public_truth_acceptance_overclaim"),
    (r"\brenders? (at|with)\b", "public_truth_acceptance_overclaim"),
    (r"\.app bundle[^\n]*\b(available|ready|released)\b", "public_truth_packaging_overclaim"),
    (r"\bcodesign[^\n]*(complete|done|available)\b", "public_truth_packaging_overclaim"),
    (r"\bcodesigned\b", "public_truth_packaging_overclaim"),
    (r"\bnotari[sz][^\n]*(complete|done|available)\b", "public_truth_packaging_overclaim"),
    (r"\bnotarized\b", "public_truth_packaging_overclaim"),
    (r"\brelease( is)? (available|ready|out|live)\b", "public_truth_release_overclaim"),
    (r"\bdownload the (app|release|installer)\b", "public_truth_packaging_overclaim"),
    (r"ready[^\n]*to merge\b", "public_truth_release_overclaim"),
    (r"\b(merge|release)[^\n]*authorized\b", "public_truth_release_overclaim"),
    (r"\broadmap[^\n]*(is )?(complete|authorized)\b", "public_truth_roadmap_invalid"),
]


def run_overclaim(text):
    """Return (fragment, guard) for the first stale / overclaiming statement."""
    for entry in STALE_PATTERNS:
        pat, guard = entry[0], entry[1]
        negatable = entry[2] if len(entry) > 2 else True
        for m in re.finditer(pat, text, flags=re.IGNORECASE):
            if negatable:
                nl = text.find("\n", m.end())
                line_end = nl if nl != -1 else len(text)
                win = text[max(0, m.start() - 20):line_end]
                if re.search(r"\b(not yet|not|no|never|without|absent|unavailable|future)\b",
                             win, flags=re.IGNORECASE):
                    continue
            return m.group(0), guard
    return None, None


# --------------------------------------------------------------------------
# README claim checks (§8, section-scoped)
# --------------------------------------------------------------------------

def check_readme(text, truth):
    # Marker checks always run on the RAW README: the marker is an HTML
    # comment and would be stripped by sanitization.
    if text.count(MARKER) == 0:
        die("public_truth_marker_missing", EXIT_POLICY,
            "README.md is missing the public product truth marker")
    if text.count(MARKER) > 1:
        die("public_truth_marker_duplicated", EXIT_POLICY,
            "README.md contains more than one public product truth marker")

    # Marker placement (raw positioning): the marker must appear AFTER the
    # sole visible product H1 (for a Setext H1 this means the title AND its
    # underline) and BEFORE the first visible H2. Only VISIBLE Markdown
    # headings (ATX or Setext) count: fenced-code or HTML-comment decoy
    # headings, and 4-space-indented code, can never supply the H1/H2 that the
    # marker must be positioned against.
    #
    # §5 (FIX3): README authority is bound to EXACTLY ONE visible level-1
    # heading whose parsed title is exactly the product display name. A wrong,
    # absent, or duplicate visible product H1 is public_truth_branding_invalid;
    # general prose naming the product cannot substitute for the product H1;
    # a product name supplied only in prose/comment/fence fails.
    disp = truth["branding"]["product_display_name"]
    headings, html_viol, _ = parse_headings(text)

    # raw-HTML headings are NOT section authority: a visible <h1>/<h2> is a
    # heading-syntax violation and must fail closed, never be adopted.
    if any(h.level == 1 for h in html_viol):
        die("public_truth_branding_invalid", EXIT_POLICY,
            "README visible raw-HTML <h1> is not a valid product H1")
    if any(h.level == 2 for h in html_viol):
        die("public_truth_docs_drift", EXIT_POLICY,
            "README visible raw-HTML <h2> is not a valid L2 section")

    h1 = [h for h in headings if h.level == 1]
    if len(h1) != 1:
        die("public_truth_branding_invalid", EXIT_POLICY,
            "README must have exactly one visible product H1, "
            f"got {len(h1)}")
    # §5 (FIX3): README authority is bound to ONE visible product H1 whose
    # parsed title is EXACTLY the product display name. Parsing is exact (no
    # emphasis stripping): an emphasized or misprinted product name cannot be
    # masked, and general prose naming the product cannot substitute for it.
    if h1[0].title != disp:
        die("public_truth_branding_invalid", EXIT_POLICY,
            f"README visible product H1 must be exactly the product name "
            f"{disp!r}, got {h1[0].title!r}")
    marker_pos = text.find(MARKER)
    if marker_pos < h1[0].end:
        die("public_truth_marker_missing", EXIT_POLICY,
            "public product truth marker must appear after the visible product H1")
    first_h2 = next((h for h in headings if h.level == 2), None)
    if first_h2 is not None and marker_pos > first_h2.start:
        die("public_truth_marker_missing", EXIT_POLICY,
            "public product truth marker is placed in an unrelated section")

    # All other evidence uses sanitized visible prose: HTML comments and
    # fenced code blocks are stripped so decoys cannot satisfy bindings.
    body = sanitize_markdown(text)

    # --- comment/fence-hidden truth ---
    if "imported" in text.lower() and "imported" not in body.lower():
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "product truth is hidden inside HTML comments or fenced blocks")

    # --- mandatory L2 sections: each exactly once on visible prose ---
    # The inventory is ORDERED and never collapsed by title, so exact
    # duplicates are always counted; ATX and Setext headings feed the same
    # exactly-once gate. Section bodies are the sanitized visible prose of each
    # owner span (nested subsections folded in). raw-HTML <h2> already failed
    # closed above, so it never reaches here as a section.
    l2 = {}
    counts = {}
    for title, sbuf in l2_inventory(text):
        counts[title] = counts.get(title, 0) + 1
        l2.setdefault(title, sbuf)
    for name in REQUIRED_README_SECTIONS:
        c = counts.get(name, 0)
        if c == 0:
            die("public_truth_docs_drift", EXIT_POLICY,
                f"README is missing required section: {name!r}")
        if c > 1:
            die("public_truth_docs_drift", EXIT_POLICY,
                f"README section is duplicated: {name!r}")

    # --- branding (visible prose only) ---
    b = truth["branding"]
    disp = b["product_display_name"]
    internal = b["internal_module_name"]
    if f"# {disp}" not in body and f"**{disp}" not in body and disp not in body:
        die("public_truth_branding_invalid", EXIT_POLICY,
            f"README does not name the product {disp}")
    if not re.search(rf"\b{re.escape(internal)}\b", body):
        die("public_truth_branding_invalid", EXIT_POLICY,
            f"README does not reference the internal module {internal}")
    if re.search(rf"\bproduct name\b[^\n]{{0,40}}{re.escape(internal)}", body,
                 flags=re.IGNORECASE) and not \
            re.search(rf"\bproduct name\b[^\n]{{0,40}}{re.escape(disp)}",
                      body, flags=re.IGNORECASE) and not \
            re.search(rf"\bproduct name\b[^\n]{{0,40}}\b(and|or)\b",
                      body, flags=re.IGNORECASE):
        die("public_truth_branding_invalid", EXIT_POLICY,
            "README asserts the internal module name as the product name")

    # --- stale / overclaiming scan on visible prose ---
    body_norm = re.sub(r"\*\*|`+|\*+", "", body)
    frag, guard = run_overclaim(body_norm)
    if frag:
        die(guard, EXIT_POLICY,
            f"README stale or overclaiming statement: {frag!r}")

    # --- helper: every fact must live in its owning section ---
    def require_facts(section_name, facts, guard):
        sec_norm = re.sub(r"\*\*|`+|\*+", "", l2.get(section_name, ""))
        for pat, label in facts:
            if not re.search(pat, sec_norm, flags=re.IGNORECASE):
                die(guard, EXIT_POLICY,
                    f"{section_name} section missing fact: {label}")

    # --- helper: subject-bound facts (§4.1) ---
    # A fact is present only when a statement in the owning section carries
    # BOTH the intended subject and the fact phrase. Generic wording ("not
    # required", "not canonical", "future") attached to a different subject
    # must not satisfy the fact.
    def require_subject_facts(section_name, facts, guard):
        sec_norm = re.sub(r"\*\*|`+|\*+", "", l2.get(section_name, ""))
        stmts = _statements(sec_norm)
        for subject, fact, label in facts:
            present = False
            for stmt in stmts:
                if re.search(subject, stmt, flags=re.IGNORECASE) and \
                        re.search(fact, stmt, flags=re.IGNORECASE):
                    present = True
                    break
            if not present:
                die(guard, EXIT_POLICY,
                    f"{section_name} section missing fact bound to "
                    f"{subject!r}: {label}")

    # §7.1 Current Status
    require_facts("Current Status", CURRENT_STATUS_FACTS, "public_truth_docs_drift")
    # §7.2 Runtime Truth: all runtime/CrossOver conditions subject-bound
    require_subject_facts("Runtime Truth", RUNTIME_TRUTH_FACTS, "public_truth_runtime_invalid")
    # §7.4 How It Works: visible prose only
    require_facts("How It Works", HOW_IT_WORKS_FACTS, "public_truth_docs_drift")
    # §7.5 Distribution Truth
    require_facts("Distribution Truth", DISTRIBUTION_TRUTH_FACTS, "public_truth_docs_drift")
    # §7.6 Safety and Privacy
    require_facts("Safety and Privacy", SAFETY_PRIVACY_FACTS, "public_truth_docs_drift")
    # §7.7 Known Limitations
    require_facts("Known Limitations", KNOWN_LIMITATIONS_FACTS, "public_truth_docs_drift")

    # §7.3 Setup Flow: ordered coordinator steps (positions must increase)
    def require_ordered(section_name, patterns, guard):
        sec_norm = re.sub(r"\*\*|`+|\*+", "", l2.get(section_name, ""))
        pos = -1
        for pat in patterns:
            m = re.search(pat, sec_norm, flags=re.IGNORECASE)
            if not m:
                die(guard, EXIT_POLICY,
                    f"{section_name} section missing ordered step: {pat!r}")
            if m.start() <= pos:
                die(guard, EXIT_POLICY,
                    f"{section_name} section steps out of order: {pat!r}")
            pos = m.end()

    require_ordered("Setup Flow", SETUP_FLOW_ORDER, "public_truth_steam_invalid")

    # --- r5 (R5 Note section must carry the exact sentence) ---
    r5_flat = re.sub(r"\s+", " ", R5_SENTENCE)
    r5_section_flat = re.sub(r"\s+", " ", l2.get("R5 Note", ""))
    if r5_flat not in r5_section_flat:
        die("public_truth_r5_invalid", EXIT_POLICY,
            "R5 Note section does not contain the exact R5 sentence")
    # --- r5 claim negation check (scan the whole visible body) ---
    r5_claim = False
    for ln in re.split(r"\n+", body):
        if re.search(r"[Pp]roof[^\n]*(performed|claimed)", ln) and \
                not re.search(r"\bno\b|\bnot\b|\bnever\b", ln, flags=re.IGNORECASE):
            r5_claim = True
    if r5_claim:
        die("public_truth_r5_invalid", EXIT_POLICY,
            "README claims R5 proof was performed or claimed")

    # --- §7.8 Completion Roadmap: planning-only, not authorized/complete, and
    # the two lanes must keep their ordered steps inside the owning section ---
    roadmap = l2.get("Completion Roadmap", "")
    if not re.search(r"planning[- ]?only|planning-only", roadmap, flags=re.IGNORECASE):
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap does not present itself as planning-only")
    if not re.search(r"neither[^\n]*authorized", roadmap, flags=re.IGNORECASE):
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap does not state neither lane is authorized")
    if not re.search(r"neither[^\n]*complete", roadmap, flags=re.IGNORECASE):
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap does not state neither lane is complete")

    def lane_scope(before, after=None):
        m = re.search(before, roadmap)
        if not m:
            return ""
        rest = roadmap[m.end():]
        if after is not None:
            n = re.search(after, rest)
            if n:
                rest = rest[:n.start()]
        return rest

    def require_lane(name, before, after, patterns, guard):
        scope = re.sub(r"\*\*|`+|\*+", "", lane_scope(before, after))
        if not scope.strip():
            die(guard, EXIT_POLICY, f"README roadmap is missing the {name} lane")
        pos = -1
        for pat in patterns:
            m = re.search(pat, scope, flags=re.IGNORECASE)
            if not m:
                die(guard, EXIT_POLICY,
                    f"{name} lane missing ordered step: {pat!r}")
            if m.start() <= pos:
                die(guard, EXIT_POLICY,
                    f"{name} lane steps out of order: {pat!r}")
            pos = m.end()

    require_lane("Minimal", r"\*\*Minimal:\*\*", r"\*\*General", MINIMAL_LANE_ORDER,
                 "public_truth_roadmap_invalid")
    require_lane("General distribution", r"\*\*General distribution:\*\*", None,
                 GENERAL_LANE_ORDER, "public_truth_roadmap_invalid")

    # --- §4.5 roadmap contradiction rejection ---
    # The planning-only / "neither authorized nor complete" statements are
    # necessary but not sufficient: a contradictory POSITIVE claim that a lane
    # is authorized or complete must be rejected anywhere in the section.
    # Negation is judged ONLY inside the matched claim span, so a correct
    # negative statement elsewhere cannot mask a contradictory positive claim.
    def reject_positive(sec, pat, guard, label):
        for m in re.finditer(pat, sec, flags=re.IGNORECASE):
            claim = m.group(0)
            if not re.search(r"\b(neither|not|never|no|without|unavailable|absent)\b",
                             claim, flags=re.IGNORECASE):
                die(guard, EXIT_POLICY,
                    f"roadmap contradictory positive claim: {label}")

    roadmap_norm = re.sub(r"\*\*|`+|\*+", "", roadmap)
    reject_positive(roadmap_norm,
                    r"\bminimal\b[^\n]{0,120}\b(authorized|complete)\b",
                    "public_truth_roadmap_invalid",
                    "Minimal lane authorized or complete")
    reject_positive(roadmap_norm,
                    r"\bgeneral\b[^\n]{0,40}\bdistribution\b[^\n]{0,80}"
                    r"\b(authorized|complete)\b",
                    "public_truth_roadmap_invalid",
                    "General distribution lane authorized or complete")



# --------------------------------------------------------------------------
# docs scan (§9): all 9 canonical docs mandatory, stale scan on all, plus
# section-scoped positive bindings for the docs with a clear owning section.
# --------------------------------------------------------------------------

def _doc_section_body(text, section_regex):
    """Return every matching owner-section body, in document order.

    §4 (FIX3): occurrences are NEVER collapsed through a heading-keyed
    dictionary. Repeated identical headings are all preserved and counted, so
    the caller's exactly-one requirement detects exact duplicates even when
    every duplicate carries the accepted bindings. No occurrence is trusted by
    "first/last match wins", and no occurrence is deduplicated by heading text
    or body digest. Only VISIBLE level-2 headings (ATX, Setext, or raw HTML
    <h2>) own a section: a fenced or commented heading is invisible and cannot
    affect the count. Each body is sanitized visible prose, so a fact hidden in
    a comment or fenced block cannot satisfy a binding.
    """
    return [sbuf for (title, sbuf) in l2_inventory(text)
            if re.search(section_regex, title, flags=re.IGNORECASE)]


# §8 canonical-doc owner bindings.  Each (rel_path, section_regex, bindings)
# entry is checked only against the sanitized visible prose of its OWNING
# section: facts hidden in comments or fenced blocks, or moved to a different
# section, must fail.
DOC_ARCHITECTURE_OVERVIEW = [
    (r"imported wine is the canonical u1 runtime|imported wine[^\n]*canonical",
     "Imported Wine canonical"),
    (r"user-selected installer", "user-selected Steam installer"),
    (r"disabled[- ]by[- ]default", "CrossOver disabled-by-default"),
    (r"explicit opt[- ]in", "CrossOver explicit opt-in"),
    (r"lowest[- ]priority", "CrossOver lowest priority"),
    (r"never a prerequisite", "CrossOver never a prerequisite"),
    (r"commercial adapter", "CrossOver non-canonical optional commercial adapter"),
]
DOC_STEAM_2 = [
    (r"user must obtain|user[- ]selected file|user-selected", "user-selected installer"),
    (r"never bundles or downloads|never[^\n]*bundle", "installer not bundled"),
    (r"never bundles or downloads|never[^\n]*download", "installer not downloaded"),
]
DOC_STEAM_3 = [
    (r"reads, stores, or transmits|never[^\n]*reads|never[^\n]*stores|never[^\n]*transmits",
     "no credential reads/storage/transmission"),
    (r"steam's authentication api|authentication api", "no auth API interaction"),
    (r"loginusers\.vdf|account-related files", "no account-file reads"),
    (r"steam itself", "auth by Steam itself"),
]


def scan_docs(root, truth):
    # (rel_path, optional section regex, [(positive_regex, label)])
    bindings = [
        ("docs/ARCHITECTURE.md", r"\bOverview\b", DOC_ARCHITECTURE_OVERVIEW),
        ("docs/CLOVERPIT_U1.md", r"Current Product Status", [
            (r"3314790", "exact Steam App ID"),
            (r"implemented-pending-local-acceptance", "implementation status"),
            (r"not (yet )?been completed|acceptance[^\n]*pending", "acceptance pending"),
            (r"playability is not", "no playability claim"),
        ]),
        ("docs/DISTRIBUTION_BOUNDARIES.md", r"Current MacsTeam Distribution Status", [
            (r"swift package development build", "Swift Package dev build"),
            (r"no downloadable .app", "no downloadable .app"),
            (r"code-signing is not complete|codesigning is not complete|code.signing is not complete",
             "codesign incomplete"),
            (r"notarization is not complete", "notarization incomplete"),
            (r"no packaged zip/dm?g/release", "no packaged release"),
            (r"release is not authorized", "release not authorized"),
        ]),
        ("docs/RUNTIME_CONTRACT.md", r"U1 Runtime Selection Contract", [
            (r"imported wine is the canonical u1 runtime", "imported-wine canonical"),
            (r"not selected by default", "system wine not default"),
            (r"future/unavailable|future . unavailable", "managed wine unavailable"),
            (r"crossover is not canonical", "crossover not canonical"),
            (r"crossover is not required", "crossover not required"),
            (r"crossover is not default-enabled|disabled by default", "crossover not default"),
        ]),
        ("docs/STEAM_BOUNDARY.md", r"^2\.\s*Steam Installer: User-Selected File Only",
         DOC_STEAM_2),
        ("docs/STEAM_BOUNDARY.md", r"^3\.\s*No Credential Access", DOC_STEAM_3),
        ("docs/ULTIMATE_ARCHITECTURE.md", r"Current Acceptance Status", [
            (r"imported wine remains the canonical u1 runtime", "imported-wine canonical"),
            (r"acceptance remain pending", "acceptance pending"),
            (r"playability is not claimed", "no playability claim"),
            (r"no packaged .app release", "no packaged .app release"),
        ]),
        ("docs/GAME_RECIPE_CONTRACT.md", None, [
            (r"store\.type.*steam|\bsteam\b.*store", "steam store boundary"),
        ]),
        ("docs/PREFIX_LIFECYCLE.md", None, [
            (r"user-(provided|overlay)|user-provided runtimes|no automatic download", "prefix boundary"),
        ]),
        ("docs/SECURITY_BOUNDARIES.md", r"\bOverview\b", [
            (r"fail-closed|fail closed", "fail-closed gate"),
        ]),
    ]

    for rel, section_regex, positive in bindings:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            die("public_truth_docs_drift", EXIT_POLICY,
                f"designated canonical doc missing: {rel}")
        text = read_text(path)
        # raw-HTML headings are never canonical-doc section authority: a
        # visible <h1>/<h2> in a canonical doc fails closed as docs drift.
        _heads, html_viol, _ = parse_headings(text)
        if html_viol:
            die("public_truth_docs_drift", EXIT_POLICY,
                f"{rel}: visible raw-HTML <h{html_viol[0].level}> is not a "
                f"valid section owner")
        body_norm = re.sub(r"\*\*|`+|\*+", "", sanitize_markdown(text))
        frag, guard = run_overclaim(body_norm)
        if frag:
            die(guard, EXIT_POLICY,
                f"{rel}: public doc drift from truth authority: {frag!r}")
        scope = text
        if section_regex is not None:
            owners = _doc_section_body(text, section_regex)
            if len(owners) != 1:
                die("public_truth_docs_drift", EXIT_POLICY,
                    f"{rel}: expected exactly one owning section for "
                    f"({section_regex!r}), got {len(owners)}")
            scope = owners[0]
        scope_norm = re.sub(r"\*\*|`+|\*+", "", scope or text)
        for pat, label in positive:
            if not re.search(pat, scope_norm, flags=re.IGNORECASE):
                die("public_truth_docs_drift", EXIT_POLICY,
                    f"{rel}: missing positive binding: {label}")


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_audit(args):
    root = os.path.abspath(args.root)
    schema_path = os.path.join(root, "Contracts", "public-product-truth.schema.json")
    truth_path = os.path.join(root, "docs", "public-product-truth.json")
    readme_path = os.path.join(root, "README.md")

    schema = read_json(schema_path, "public_truth_schema_io_error",
                       "public_truth_schema_parse_error")
    truth = read_json(truth_path, "public_truth_authority_io_error",
                      "public_truth_authority_parse_error")
    readme = read_text_guard(readme_path, "public_truth_readme_io_error")

    # Ordering (§7): 1) authority-vs-schema -> schema_invalid;
    #                2) independent semantics -> semantic_invalid;
    #                3) schema self-contract -> schema_invalid.
    err = _validate(truth, schema, "$")
    if err:
        die("public_truth_schema_invalid", EXIT_POLICY,
            f"authority schema violation: {err}")

    se = semantic_validate(truth)
    if se:
        detail = _semantic_detail or se
        die(se, EXIT_POLICY, f"authority semantic violation: {se}: {detail}")

    contract_err = schema_contract_violation(schema)
    if contract_err:
        die("public_truth_schema_invalid", EXIT_POLICY,
            f"schema contract violation (schema weakened): {contract_err}")

    check_readme(readme, truth)
    scan_docs(root, truth)

    print("Public product truth audit passed.")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="MacsTeam public product truth audit")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("audit", help="audit the public product truth of a repo root")
    p.add_argument("--root", required=True)
    p.set_defaults(func=cmd_audit)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise