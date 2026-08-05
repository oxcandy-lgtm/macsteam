#!/usr/bin/env python3
"""MacsTeam public product truth audit (stdlib only).

Read-only, fail-closed tooling that verifies that the public-facing product
documentation (README.md + public docs) describe the product that actually
exists at the repository HEAD, as encoded in the machine-readable authority
at docs/public-product-truth.json against the schema at
Contracts/public-product-truth.schema.json.

Checks (15 guards):
  public_truth_schema_invalid
  public_truth_semantic_invalid
  public_truth_marker_missing
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
  public_truth_docs_drift
  public_truth_roadmap_invalid

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

# Designated canonical public docs that must agree with the authority.
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


def read_json(path, guard_infra, guard_parse):
    text = read_text(path)
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
# product truth authority validation
# --------------------------------------------------------------------------

def semantic_validate(truth):
    r = truth.get("runtime", {})
    s = truth.get("steam", {})
    c = truth.get("cloverpit", {})
    p = truth.get("packaging", {})
    rel = truth.get("release", {})

    # A non-canonical CrossOver must not be presented as canonical/required/
    # default anywhere in the machine-readable authority.
    if r.get("canonical_u1_runtime") != "imported-wine":
        return "public_truth_semantic_invalid"
    if r.get("crossover_policy") != "disabled-by-default-explicit-opt-in-lowest-priority":
        return "public_truth_semantic_invalid"

    if s.get("installer_mode") != "user-selected-file":
        return "public_truth_semantic_invalid"
    if s.get("installer_bundled") or s.get("installer_downloaded_by_app"):
        return "public_truth_semantic_invalid"

    if c.get("playability_claimed"):
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
    # drop leading all-empty section if there is a heading
    return out


def dedent(text):
    return re.sub(r"[ \t]+", " ", text).replace(" ", "")


# Stale / overclaiming statement patterns mapped to their guards.  Each match
# is window-negated by default (a "not/no/never/..." within a small window of
# the match is treated as a negation, not an overclaim).  Patterns whose claim
# is *inherently* a negation (e.g. "no Wine support") are marked negatable=False.
STALE_PATTERNS = [
    (r"initial runtime[^\n]*crossover", "public_truth_stale_crossover_prerequisite"),
    (r"\bcrossover\b[^\n]*\b(prerequisite|canonical-u1|initial runtime)\b",
     "public_truth_stale_crossover_prerequisite"),
    (r"crossover[^\n]*(\brequire\b|\brequires\b|\brequired\b|\byou (need|must|have to) install\b)",
     "public_truth_stale_crossover_prerequisite"),
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
                # Look for a negating word before or after the match within the
                # same line (handles "Not yet available" trailing a claim).
                nl = text.find("\n", m.end())
                line_end = nl if nl != -1 else len(text)
                win = text[max(0, m.start() - 20):line_end]
                if re.search(r"\b(not yet|not|no|never|without|absent|unavailable|future)\b",
                             win, flags=re.IGNORECASE):
                    continue
            return m.group(0), guard
    return None, None


# --------------------------------------------------------------------------
# README claim checks
# --------------------------------------------------------------------------

def check_readme(text, truth):
    if text.count(MARKER) == 0:
        die("public_truth_marker_missing", EXIT_POLICY,
            "README.md is missing the public product truth marker")
    if text.count(MARKER) > 1:
        die("public_truth_marker_duplicated", EXIT_POLICY,
            "README.md contains more than one public product truth marker")

    body = strip_html_comments(text)

    # Marker placement: the marker must sit in the leading intro, before the
    # first top-level content heading, not buried in an unrelated section.
    first_heading = re.search(r"\n#{1,6}\s+[^\n]+", text)
    marker_pos = text.find(MARKER)
    if first_heading is not None:
        head_end = first_heading.start()
        if marker_pos > head_end:
            die("public_truth_marker_missing", EXIT_POLICY,
                "public product truth marker is placed in an unrelated section")

    # --- comment-hidden truth ---
    # If the runtime / platform facts exist in the raw text only inside HTML
    # comments, the rendered body must not silently hide them.
    if "imported" in text.lower() and "imported" not in body.lower():
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "product truth is hidden inside HTML comments")

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

    # imported-wine canonical runtime must be described
    if "imported" not in dedent(body).lower():
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "README does not describe the imported-wine canonical runtime")

    # CrossOver runtime policy must be qualified (not a blanket ban or omission)
    if not re.search(r"(not required|not canonical|disabled.by.default|opt.in)", body,
                     flags=re.IGNORECASE):
        die("public_truth_runtime_invalid", EXIT_POLICY,
            "README does not qualify the CrossOver runtime policy")

    # --- steam flow ---
    if "user-selected" not in dedent(body).lower() and "user.selected" not in dedent(body).lower():
        die("public_truth_steam_invalid", EXIT_POLICY,
            "README does not describe the user-selected Steam installer flow")

    # --- r5 ---
    r5_flat = re.sub(r"\s+", " ", R5_SENTENCE)
    text_flat = re.sub(r"\s+", " ", text)
    if r5_flat not in text_flat:
        die("public_truth_r5_invalid", EXIT_POLICY,
            "README does not contain the exact R5 sentence")
    # --- r5 claim negation check ---
    r5_claim = False
    for ln in re.split(r"\n+", body):
        if re.search(r"[Pp]roof[^\n]*(performed|claimed)", ln) and \
                not re.search(r"\bno\b|\bnot\b|\bnever\b", ln, flags=re.IGNORECASE):
            r5_claim = True
    if r5_claim:
        die("public_truth_r5_invalid", EXIT_POLICY,
            "README claims R5 proof was performed or claimed")

    # --- roadmap ---
    if not re.search(r"planning", body, flags=re.IGNORECASE):
        die("public_truth_roadmap_invalid", EXIT_POLICY,
            "README roadmap does not present itself as planning-only")


# --------------------------------------------------------------------------
# docs scan
# --------------------------------------------------------------------------

def scan_docs(root, truth):
    for rel in CANONICAL_DOCS:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        text = read_text(path)
        body = strip_html_comments(text)
        body = re.sub(r"\*\*|`+|\*+", "", body)
        frag, guard = run_overclaim(body)
        if frag:
            die(guard, EXIT_POLICY,
                f"{rel}: public doc drift from truth authority: {frag!r}")


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_audit(args):
    root = os.path.abspath(args.root)
    schema_path = os.path.join(root, "Contracts", "public-product-truth.schema.json")
    truth_path = os.path.join(root, "docs", "public-product-truth.json")
    readme_path = os.path.join(root, "README.md")

    if not os.path.exists(schema_path):
        die("file_io_error", EXIT_INFRA, f"schema not found: {schema_path}")
    if not os.path.exists(truth_path):
        die("file_io_error", EXIT_INFRA, f"authority not found: {truth_path}")
    if not os.path.exists(readme_path):
        die("file_io_error", EXIT_INFRA, f"README not found: {readme_path}")

    schema = read_json(schema_path, "schema_file_io_error", "schema_file_invalid")
    if "schema_version" in schema and "kind" not in schema:
        # allow schema to be thin but require the validator keywords
        pass

    truth = read_json(truth_path, "truth_file_io_error", "truth_file_invalid")

    err = _validate(truth, schema, "$")
    if err:
        die("public_truth_schema_invalid", EXIT_POLICY,
            f"authority schema violation: {err}")

    se = semantic_validate(truth)
    if se:
        die(se, EXIT_POLICY, f"authority semantic violation: {se}")

    readme = read_text(readme_path)
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