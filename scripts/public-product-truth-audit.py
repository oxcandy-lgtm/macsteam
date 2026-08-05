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

def _require_value(prop, expected):
    """Return None if prop keeps an exact const == expected, else a message."""
    if not isinstance(prop, dict):
        return f"property block not an object: {prop!r}"
    if prop.get("const") != expected:
        return f"const removed or changed (expected {expected!r}, got {prop.get('const')!r})"
    return None


def _require_closed(obj, required, props):
    """Return None if obj keeps required set, additionalProperties:false, and
    every key in props is present.  props is {key: expected_const_or_None}."""
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
    for key, expected in props.items():
        if key not in properties:
            return f"property {key!r} removed"
        if expected is not None:
            err = _require_value(properties[key], expected)
            if err:
                return f"{key}: {err}"
    return None


# Full expected shape of the product truth schema contract.  Booleans are
# represented as the Python values we require the const to equal.
SCHEMA_CONTRACT_TOP = {
    "required": ["schema_version", "kind", "branding", "platform", "runtime",
                 "steam", "cloverpit", "packaging", "release", "r5"],
    "props": {
        "schema_version": 1,
        "kind": "macsteam_public_product_truth",
    },
}

SCHEMA_CONTRACT_SECTIONS = {
    "branding": {
        "required": ["product_display_name", "internal_module_name"],
        "props": {"product_display_name": "MacsTeam",
                  "internal_module_name": "MacSteam"},
    },
    "platform": {
        "required": ["operating_system", "minimum_version", "architecture"],
        "props": {"operating_system": "macOS", "minimum_version": "15.0",
                  "architecture": "Apple Silicon"},
    },
    "runtime": {
        "required": ["canonical_u1_runtime", "system_wine_discoverable",
                     "system_wine_selected_by_default", "managed_wine_available",
                     "crossover_canonical", "crossover_required",
                     "crossover_default_enabled", "crossover_policy"],
        "props": {
            "canonical_u1_runtime": "imported-wine",
            "system_wine_discoverable": True,
            "system_wine_selected_by_default": False,
            "managed_wine_available": False,
            "crossover_canonical": False,
            "crossover_required": False,
            "crossover_default_enabled": False,
            "crossover_policy": "disabled-by-default-explicit-opt-in-lowest-priority",
        },
    },
    "steam": {
        "required": ["installer_mode", "installer_bundled",
                     "installer_downloaded_by_app", "credentials_accessed"],
        "props": {"installer_mode": "user-selected-file",
                  "installer_bundled": False,
                  "installer_downloaded_by_app": False,
                  "credentials_accessed": False},
    },
    "cloverpit": {
        "required": ["steam_app_id", "implementation_status",
                     "playability_claimed"],
        "props": {"steam_app_id": "3314790",
                  "implementation_status": "implemented-pending-local-acceptance",
                  "playability_claimed": False},
    },
    "packaging": {
        "required": ["current_distribution", "app_bundle_available",
                     "codesigned", "notarized", "packaged_release_available"],
        "props": {"current_distribution": "swift-package-development-build",
                  "app_bundle_available": False, "codesigned": False,
                  "notarized": False, "packaged_release_available": False},
    },
    "release": {
        "required": ["pull_request_draft", "ready_authorized",
                     "merge_authorized", "release_authorized"],
        "props": {"pull_request_draft": True, "ready_authorized": False,
                  "merge_authorized": False, "release_authorized": False},
    },
    "r5": {
        "required": ["external_real_mac_proof_requirement_removed",
                     "external_real_mac_proof_performed",
                     "external_real_mac_proof_claimed"],
        "props": {"external_real_mac_proof_requirement_removed": True,
                  "external_real_mac_proof_performed": False,
                  "external_real_mac_proof_claimed": False},
    },
}


def schema_contract_violation(schema):
    """Return a human-readable violation if the schema is weakened, else None."""
    if not isinstance(schema, dict):
        return "schema root is not an object"
    top_err = _require_closed(schema, SCHEMA_CONTRACT_TOP["required"],
                              SCHEMA_CONTRACT_TOP["props"])
    if top_err:
        return f"top-level: {top_err}"
    properties = schema.get("properties", {})
    for key, contract in SCHEMA_CONTRACT_SECTIONS.items():
        if key not in properties:
            return f"section {key!r} removed from schema"
        err = _require_closed(properties[key], contract["required"], contract["props"])
        if err:
            return f"section {key!r}: {err}"
    return None


# --------------------------------------------------------------------------
# product truth authority validation
# --------------------------------------------------------------------------

def semantic_validate(truth):
    r = truth.get("runtime", {})
    s = truth.get("steam", {})
    c = truth.get("cloverpit", {})
    p = truth.get("packaging", {})
    rel = truth.get("release", {})

    if r.get("canonical_u1_runtime") != "imported-wine":
        return "public_truth_semantic_invalid"
    if r.get("crossover_policy") != "disabled-by-default-explicit-opt-in-lowest-priority":
        return "public_truth_semantic_invalid"

    if s.get("installer_mode") != "user-selected-file":
        return "public_truth_semantic_invalid"
    if s.get("installer_bundled") or s.get("installer_downloaded_by_app"):
        return "public_truth_semantic_invalid"

    if c.get("playability_claimed") or c.get("implementation_status") != \
            "implemented-pending-local-acceptance":
        return "public_truth_semantic_invalid"
    if c.get("steam_app_id") != "3314790":
        return "public_truth_semantic_invalid"

    if p.get("current_distribution") != "swift-package-development-build":
        return "public_truth_semantic_invalid"
    if p.get("packaged_release_available"):
        return "public_truth_semantic_invalid"

    if rel.get("ready_authorized") or rel.get("merge_authorized") or rel.get("release_authorized"):
        return "public_truth_semantic_invalid"
    if not rel.get("pull_request_draft"):
        return "public_truth_semantic_invalid"

    if not truth.get("r5", {}).get("external_real_mac_proof_requirement_removed"):
        return "public_truth_semantic_invalid"
    if truth.get("r5", {}).get("external_real_mac_proof_performed"):
        return "public_truth_semantic_invalid"
    if truth.get("r5", {}).get("external_real_mac_proof_claimed"):
        return "public_truth_semantic_invalid"

    return None


# --------------------------------------------------------------------------
# markdown helpers
# --------------------------------------------------------------------------

def strip_html_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def sections(text):
    """Return a list of (heading_level, heading, body) tuples."""
    out = []
    lines = text.splitlines()
    current = (0, "", [])
    for line in lines:
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            out.append((current[0], current[1], "\n".join(current[2])))
            current = (len(m.group(1)), m.group(2), [])
        else:
            current[2].append(line)
    out.append((current[0], current[1], "\n".join(current[2])))
    return out


def l2_sections(text):
    """Return {heading: body} for every level-2 heading."""
    result = {}
    for lvl, heading, body in sections(text):
        if lvl == 2:
            result[heading.strip()] = body
    return result


def dedent(text):
    return re.sub(r"[ \t]+", " ", text).replace(" ", "")


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
    if text.count(MARKER) == 0:
        die("public_truth_marker_missing", EXIT_POLICY,
            "README.md is missing the public product truth marker")
    if text.count(MARKER) > 1:
        die("public_truth_marker_duplicated", EXIT_POLICY,
            "README.md contains more than one public product truth marker")

    body = strip_html_comments(text)

    # Marker placement: must sit in the leading intro, before the first level-2
    # heading, not buried in an unrelated section.
    first_l2 = None
    for lvl, heading, _ in sections(text):
        if lvl == 2:
            first_l2 = (lvl, heading)
            break
    marker_pos = text.find(MARKER)
    if first_l2 is not None:
        head_start = text.find("#" * first_l2[0] + " " + first_l2[1])
        if marker_pos > head_start:
            die("public_truth_marker_missing", EXIT_POLICY,
                "public product truth marker is placed in an unrelated section")

    # --- comment-hidden truth ---
    if "imported" in text.lower() and "imported" not in body.lower():
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "product truth is hidden inside HTML comments")

    # --- mandatory L2 sections: each exactly once ($8) ---
    l2 = l2_sections(text)
    counts = {}
    for lvl, heading, _ in sections(text):
        if lvl == 2:
            counts[heading.strip()] = counts.get(heading.strip(), 0) + 1
    for name in REQUIRED_README_SECTIONS:
        if counts.get(name, 0) == 0:
            die("public_truth_docs_drift", EXIT_POLICY,
                f"README is missing required section: {name!r}")
        if counts.get(name, 0) > 1:
            die("public_truth_docs_drift", EXIT_POLICY,
                f"README section is duplicated: {name!r}")

    # --- branding ---
    b = truth["branding"]
    disp = b["product_display_name"]
    internal = b["internal_module_name"]
    if f"# {disp}" not in text and f"**{disp}" not in text and disp not in text:
        die("public_truth_branding_invalid", EXIT_POLICY,
            f"README does not name the product {disp}")
    if not re.search(rf"\b{re.escape(internal)}\b", text):
        die("public_truth_branding_invalid", EXIT_POLICY,
            f"README does not reference the internal module {internal}")
    if re.search(rf"\bproduct name\b[^\n]{{0,40}}{re.escape(internal)}", text,
                 flags=re.IGNORECASE) and not \
            re.search(rf"\bproduct name\b[^\n]{{0,40}}{re.escape(disp)}",
                      text, flags=re.IGNORECASE) and not \
            re.search(rf"\bproduct name\b[^\n]{{0,40}}\b(and|or)\b",
                      text, flags=re.IGNORECASE):
        die("public_truth_branding_invalid", EXIT_POLICY,
            "README asserts the internal module name as the product name")

    # --- runtime / steam / acceptance / packaging / release stale scan ---
    body_norm = re.sub(r"\*\*|`+|\*+", "", body)
    frag, guard = run_overclaim(body_norm)
    if frag:
        die(guard, EXIT_POLICY,
            f"README stale or overclaiming statement: {frag!r}")

    # --- section-owned runtime truth: the Runtime Truth section must describe
    # the imported-wine canonical runtime and qualify the CrossOver policy ---
    rt_section = l2.get("Runtime Truth", "")
    rt_norm = re.sub(r"\*\*|`+|\*+", "", rt_section)
    if "imported" not in dedent(rt_norm).lower():
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "Runtime Truth section does not describe the imported-wine runtime")
    if "imported" not in l2.get("Run", "") and "imported" not in l2.get("How It Works", ""):
        pass  # Run/How It Works are optional owners; the Runtime Truth section rules.
    if not re.search(r"(not required|not canonical|disabled.by.default|opt.in)", rt_norm,
                     flags=re.IGNORECASE):
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "Runtime Truth section does not qualify the CrossOver policy")

    # --- steam flow (Setup Flow / Distribution Truth / Safety and Privacy) ---
    steam_blob = l2.get("Setup Flow", "") + " " + l2.get("Safety and Privacy", "") + \
        " " + l2.get("Distribution Truth", "")
    steam_flow = dedent(steam_blob).lower()
    if not re.search(r"user[- .]selected|user[- .]obtained|user-provided|user decided|user chooses",
                     steam_flow):
        die("public_truth_steam_invalid", EXIT_POLICY,
            "README does not describe the user-selected Steam installer flow")

    # --- r5 (R5 Note section must carry the exact sentence) ---
    r5_flat = re.sub(r"\s+", " ", R5_SENTENCE)
    r5_section_flat = re.sub(r"\s+", " ", l2.get("R5 Note", ""))
    if r5_flat not in r5_section_flat:
        die("public_truth_r5_invalid", EXIT_POLICY,
            "R5 Note section does not contain the exact R5 sentence")
    # --- r5 claim negation check (scan the whole rendered body) ---
    r5_claim = False
    for ln in re.split(r"\n+", body):
        if re.search(r"[Pp]roof[^\n]*(performed|claimed)", ln) and \
                not re.search(r"\bno\b|\bnot\b|\bnever\b", ln, flags=re.IGNORECASE):
            r5_claim = True
    if r5_claim:
        die("public_truth_r5_invalid", EXIT_POLICY,
            "README claims R5 proof was performed or claimed")

    # --- roadmap §8: the Completion Roadmap section must carry both lanes and
    # must present itself as planning-only ---
    roadmap = l2.get("Completion Roadmap", "")
    if "planning" not in roadmap.lower():
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap does not present itself as planning-only")
    if not re.search(r"\b[minimal]\b.*roadmap", roadmap, flags=re.IGNORECASE) and \
            "Minimal" not in roadmap:
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap is missing the Minimal lane")
    if "General distribution" not in roadmap:
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap is missing the General distribution lane")


# --------------------------------------------------------------------------
# docs scan (§9): all 9 canonical docs mandatory, stale scan on all, plus
# section-scoped positive bindings for the docs with a clear owning section.
# --------------------------------------------------------------------------

def _doc_section_body(text, section_regex):
    body_map = {}
    for lvl, heading, body in sections(text):
        body_map[heading.strip()] = body
    for heading, b in body_map.items():
        if re.search(section_regex, heading, flags=re.IGNORECASE):
            return b
    return None


def scan_docs(root, truth):
    # (rel_path, optional section regex, [(positive_regex, label)])
    bindings = [
        ("docs/ARCHITECTURE.md", r"\bOverview\b", [
            (r"imported wine[^\n]*canonical", "imported-wine canonical"),
            (r"user-selected installer", "user-selected installer"),
        ]),
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
        ("docs/STEAM_BOUNDARY.md", r"User-Selected File Only", [
            (r"user[- ]selected|user must obtain|user-provided", "user-selected installer"),
            (r"never bundles or downloads the steam installer", "installer not bundled/downloaded"),
        ]),
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
        body_norm = re.sub(r"\*\*|`+|\*+", "", strip_html_comments(text))
        frag, guard = run_overclaim(body_norm)
        if frag:
            die(guard, EXIT_POLICY,
                f"{rel}: public doc drift from truth authority: {frag!r}")
        scope = text
        if section_regex is not None:
            scope = _doc_section_body(strip_html_comments(text), section_regex)
        if section_regex is not None and scope is None:
            die("public_truth_docs_drift", EXIT_POLICY,
                f"{rel}: missing owning section for positive binding "
                f"({section_regex!r})")
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
        die(se, EXIT_POLICY, f"authority semantic violation: {se}")

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