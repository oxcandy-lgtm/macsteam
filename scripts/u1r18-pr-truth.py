#!/usr/bin/env python3
"""U1R18 PR canonical truth renderer (stdlib only).

Read-only tooling that validates a machine-readable canonical U1R18 state and
re-renders only the leading canonical block of a PR body while preserving the
historical suffix byte-for-byte. No network access and no GitHub writes.

Commands:
  validate-state --state <state.json>
  inspect-body  --body <pr-body.md>
  render        --state <state.json> --body <old.md> --output <new.md>
  verify-render --state <state.json> --before <old.md> --after <new.md>

Exit codes:
  1: policy / input contract violation
  2: filesystem / parse / infrastructure failure
"""

import argparse
import hashlib
import json
import os
import re
import sys

MARKER = "<!-- macsteam-u1r18-canonical-state:v1 -->"
HEADING = "## Canonical U1R18 State"
SENTINEL = (
    "Everything below this canonical block is retained as historical "
    "development context and may reference superseded commits, CI runs, "
    "intermediate classifications, or earlier pending work."
)
R5_SENTENCE = (
    "R5 external real-Mac proof requirement was removed by product-owner "
    "decision. No external proof was performed or claimed."
)

EXIT_POLICY = 1
EXIT_INFRA = 2

SCHEMA_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "Contracts",
    "u1r18-canonical-state.schema.json",
)

SHA_RE = re.compile(r"^[a-f0-9]{40}$")
ID_RE = re.compile(r"^R([0-9]+)$")
CLASS_RE = re.compile(r"^[A-Z0-9_]+$")

CANONICAL_ORDER = [
    "schema_version",
    "kind",
    "repository",
    "pull_request",
    "branch",
    "base_branch",
    "head_sha",
    "pr",
    "workstreams",
    "review_gate",
    "core_ci",
    "gate_advance",
    "authorization",
]

CHILD_ORDER = {
    "pr": ["state", "draft", "merged", "mergeable"],
    "workstreams": [
        "id",
        "state",
        "classification",
        "external_real_mac_proof_performed",
        "external_real_mac_proof_claimed",
    ],
    "review_gate": [
        "worker_report_comment_id",
        "submission_run_id",
        "controller_review_id",
        "live_review_run_id",
        "final_state",
        "worker_report_valid",
        "controller_review_valid",
        "nx_required",
        "next_workstream_admitted",
    ],
    "core_ci": ["run_id", "required_jobs_success"],
    "gate_advance": ["run_id", "state", "parent_authority"],
    "authorization": [
        "next_workstream_defined",
        "ready_authorized",
        "merge_authorized",
        "release_authorized",
    ],
}


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


def write_text(path, text):
    try:
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
    except OSError as exc:
        die("file_io_error", EXIT_INFRA, f"cannot write {path}: {exc}")


def sha256_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# JSON Schema validator (draft-07 subset covering the canonical state schema)
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
    if isinstance(instance, str) and "pattern" in schema:
        if not re.fullmatch(schema["pattern"], instance):
            return f"{path}: {instance!r} does not match pattern {schema['pattern']!r}"
    if (
        isinstance(instance, (int, float))
        and not isinstance(instance, bool)
        and "minimum" in schema
        and instance < schema["minimum"]
    ):
        return f"{path}: {instance} is below minimum {schema['minimum']}"

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

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            return f"{path}: fewer than {schema['minItems']} items"
        if "items" in schema:
            for idx, item in enumerate(instance):
                err = _validate(item, schema["items"], f"{path}[{idx}]")
                if err:
                    return err

    if "oneOf" in schema:
        matches = 0
        for sub in schema["oneOf"]:
            if _validate(instance, sub, path) is None:
                matches += 1
        if matches != 1:
            return f"{path}: expected exactly one matching branch, got {matches}"

    return None


def load_schema():
    try:
        with open(SCHEMA_PATH, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        die("schema_file_io_error", EXIT_INFRA, f"cannot read schema: {exc}")
    except ValueError as exc:
        die("schema_file_invalid", EXIT_INFRA, f"schema is not valid JSON: {exc}")


def load_state(path):
    text = read_text(path)
    try:
        state = json.loads(text)
    except ValueError as exc:
        die("state_json_parse_error", EXIT_INFRA, f"state is not valid JSON: {exc}")
    schema = load_schema()
    err = _validate(state, schema, "$")
    if err:
        die("state_schema_invalid", EXIT_POLICY, f"state schema violation: {err}")
    guard = semantic_validate(state)
    if guard:
        die(guard, EXIT_POLICY, f"semantic validation failed: {guard}")
    return state


# --------------------------------------------------------------------------
# Semantic validation
# --------------------------------------------------------------------------

def semantic_validate(state):
    head = state.get("head_sha", "")
    if not SHA_RE.fullmatch(head):
        return "state_head_invalid"

    pr = state.get("pr", {})
    if pr.get("state") != "open":
        return "state_semantic_invalid"
    if pr.get("draft") is not True:
        return "state_semantic_invalid"
    if pr.get("merged") is not False:
        return "state_semantic_invalid"
    if pr.get("mergeable") is not True:
        return "state_pr_mergeable_invalid"

    workstreams = state.get("workstreams", [])
    seen = set()
    last_num = -1
    for item in workstreams:
        wid = item.get("id", "")
        m = ID_RE.fullmatch(wid)
        if not m:
            return "state_semantic_invalid"
        num = int(m.group(1))
        if wid in seen:
            return "state_semantic_invalid"
        seen.add(wid)
        if num <= last_num:
            return "state_semantic_invalid"
        last_num = num
        if wid == "R5":
            if item.get("state") != "EXTERNAL_PROOF_REQUIREMENT_REMOVED":
                return "state_semantic_invalid"
            if item.get("external_real_mac_proof_performed") is not False:
                return "state_semantic_invalid"
            if item.get("external_real_mac_proof_claimed") is not False:
                return "state_semantic_invalid"
        else:
            if item.get("state") != "CLOSED":
                return "state_semantic_invalid"
            if not CLASS_RE.fullmatch(item.get("classification", "")):
                return "state_semantic_invalid"

    rg = state.get("review_gate", {})
    for key in (
        "worker_report_comment_id",
        "submission_run_id",
        "controller_review_id",
        "live_review_run_id",
    ):
        value = rg.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            return "state_semantic_invalid"

    if rg.get("final_state") != "REVIEW_COMPLETE_NX_REQUIRED":
        return "state_review_final_state_invalid"
    if rg.get("worker_report_valid") is not True:
        return "state_worker_report_valid_invalid"
    if rg.get("controller_review_valid") is not True:
        return "state_controller_review_valid_invalid"
    if rg.get("nx_required") is not True:
        return "state_nx_required_invalid"

    cc = state.get("core_ci", {})
    if not isinstance(cc.get("run_id"), int) or cc.get("run_id") < 1:
        return "state_semantic_invalid"
    ga = state.get("gate_advance", {})
    if not isinstance(ga.get("run_id"), int) or ga.get("run_id") < 1:
        return "state_semantic_invalid"
    if ga.get("state") != "CURRENT_WORKSTREAM_ACTIVE":
        return "state_gate_advance_state_invalid"
    if ga.get("parent_authority") != "controller_review":
        return "state_gate_parent_authority_invalid"

    if rg.get("next_workstream_admitted") is True:
        return "unsafe_authorization"

    auth = state.get("authorization", {})
    if auth.get("next_workstream_defined") is True:
        return "unsafe_authorization"
    for key in ("ready_authorized", "merge_authorized", "release_authorized"):
        if auth.get(key) is True:
            return "unsafe_authorization"

    return None


# --------------------------------------------------------------------------
# Deterministic YAML emission (fixed-order, stdlib only)
# --------------------------------------------------------------------------

YAML_RESERVED = {"true", "false", "null", "yes", "no", "on", "off", "~"}


def fmt_scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        if value and re.fullmatch(r"[A-Za-z0-9_./:+-]+", value) and value not in YAML_RESERVED:
            return value
        return "'" + value.replace("'", "''") + "'"
    return str(value)


def _keys_in_order(data, order):
    if order:
        ordered = [k for k in order if k in data]
    else:
        ordered = []
    for k in data:
        if k not in ordered:
            ordered.append(k)
    return ordered


def emit_yaml(data, order_key, indent=0):
    pad = "  " * indent
    if order_key == "root":
        order = CANONICAL_ORDER
    else:
        order = CHILD_ORDER.get(order_key)
    lines = []
    if isinstance(data, dict):
        keys = _keys_in_order(data, order)
        for key in keys:
            value = data[key]
            child_key = key if key in CHILD_ORDER else order_key
            if isinstance(value, (dict, list)):
                lines.append(f"{pad}{key}:")
                lines.extend(emit_yaml(value, child_key, indent + 1))
            else:
                lines.append(f"{pad}{key}: {fmt_scalar(value)}")
    elif isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                first = True
                keys = _keys_in_order(item, order)
                for key in keys:
                    value = item[key]
                    prefix = f"{pad}- " if first else f"{pad}  "
                    first = False
                    if isinstance(value, (dict, list)):
                        lines.append(f"{prefix}{key}:")
                        lines.extend(emit_yaml(value, order_key, indent + 2))
                    else:
                        lines.append(f"{prefix}{key}: {fmt_scalar(value)}")
            else:
                lines.append(f"{pad}- {fmt_scalar(item)}")
    else:
        lines.append(f"{pad}{fmt_scalar(data)}")
    return lines


def canonical_yaml(state):
    return "\n".join(emit_yaml(state, "root"))


def build_block(state):
    yaml_text = canonical_yaml(state)
    return (
        MARKER
        + "\n"
        + HEADING
        + "\n\n```yaml\n"
        + yaml_text
        + "\n```\n\n"
        + R5_SENTENCE
        + "\n\n"
        + SENTINEL
    )


# --------------------------------------------------------------------------
# Body parsing
# --------------------------------------------------------------------------

def validate_body_guards(body):
    marker_count = body.count(MARKER)
    sentinel_count = body.count(SENTINEL)
    if marker_count == 0:
        die("body_marker_missing", EXIT_POLICY, "canonical marker missing")
    if marker_count > 1:
        die("body_marker_duplicated", EXIT_POLICY, "canonical marker duplicated")
    if sentinel_count == 0:
        die("body_sentinel_missing", EXIT_POLICY, "historical sentinel missing")
    if sentinel_count > 1:
        die("body_sentinel_duplicated", EXIT_POLICY, "historical sentinel duplicated")
    marker_pos = body.find(MARKER)
    sentinel_pos = body.find(SENTINEL)
    if not (0 <= marker_pos < sentinel_pos):
        die("body_order_invalid", EXIT_POLICY, "marker must precede sentinel")
    block_end = sentinel_pos + len(SENTINEL)
    if body[block_end : block_end + 1] == "\n":
        block_end += 1
    return block_end


def extract_yaml_block(body, start, end):
    segment = body[start:end]
    m = re.search(r"```yaml\n(.*?)\n```", segment, re.DOTALL)
    return m.group(1) if m else segment


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_validate_state(args):
    load_state(args.state)
    print(json.dumps({"ok": True, "guard": None}))


def cmd_inspect_body(args):
    body = read_text(args.body)
    marker_count = body.count(MARKER)
    sentinel_count = body.count(SENTINEL)
    head_found = None
    stale_r8 = False
    suffix_digest = None
    marker_pos = body.find(MARKER)
    sentinel_pos = body.find(SENTINEL)
    if marker_count >= 1 and sentinel_count >= 1 and 0 <= marker_pos < sentinel_pos:
        yaml_text = extract_yaml_block(body, marker_pos, sentinel_pos)
        m = re.search(r"(?m)^head(?:_sha)?:\s*([a-f0-9]{40})\b", yaml_text)
        if m:
            head_found = m.group(1)
        stale_r8 = bool(re.search(r"(?m)^\s*r8_defined:\s*false\b", yaml_text))
        block_end = sentinel_pos + len(SENTINEL)
        if body[block_end : block_end + 1] == "\n":
            block_end += 1
        suffix_digest = sha256_hex(body[block_end:])
    result = {
        "marker_count": marker_count,
        "sentinel_count": sentinel_count,
        "canonical_head_found": head_found,
        "stale_r8_defined_false_found": stale_r8,
        "historical_suffix_digest": suffix_digest,
    }
    print(json.dumps(result))


def cmd_render(args):
    state = load_state(args.state)
    body = read_text(args.body)
    block_end = validate_body_guards(body)
    old_suffix = body[block_end:]
    block = build_block(state)
    new_body = block + "\n" + old_suffix

    if new_body.count(MARKER) != 1:
        die("output_marker_count_invalid", EXIT_POLICY, "output marker count != 1")
    if new_body.count(SENTINEL) != 1:
        die("output_sentinel_count_invalid", EXIT_POLICY, "output sentinel count != 1")
    if block.count(R5_SENTENCE) != 1:
        die("r5_contract_invalid", EXIT_POLICY, "R5 sentence must appear exactly once")
    old_sentinel_pos = body.find(SENTINEL)
    new_sentinel_pos = new_body.find(SENTINEL)
    if new_body[new_sentinel_pos:] != body[old_sentinel_pos:]:
        die("historical_suffix_changed", EXIT_POLICY, "historical region changed")

    write_text(args.output, new_body)
    print(
        json.dumps(
            {
                "ok": True,
                "output": args.output,
                "marker_count": 1,
                "sentinel_count": 1,
                "r5_sentence_count": 1,
                "historical_suffix_digest": sha256_hex(old_suffix),
            }
        )
    )


def cmd_verify_render(args):
    state = load_state(args.state)
    before = read_text(args.before)
    after = read_text(args.after)

    before_block_end = validate_body_guards(before)
    before_suffix = before[before_block_end:]

    after_marker_count = after.count(MARKER)
    after_sentinel_count = after.count(SENTINEL)
    if after_marker_count != 1:
        die("output_marker_count_invalid", EXIT_POLICY, "after marker count != 1")
    if after_sentinel_count != 1:
        die("output_sentinel_count_invalid", EXIT_POLICY, "after sentinel count != 1")
    after_marker_pos = after.find(MARKER)
    after_sentinel_pos = after.find(SENTINEL)
    if not (0 <= after_marker_pos < after_sentinel_pos):
        die("body_order_invalid", EXIT_POLICY, "marker must precede sentinel")

    expected_block = build_block(state)
    actual_block = after[after_marker_pos : after_sentinel_pos + len(SENTINEL)]
    if actual_block != expected_block:
        die("output_state_mismatch", EXIT_POLICY, "rendered canonical block mismatch")
    if expected_block.count(R5_SENTENCE) != 1:
        die("r5_contract_invalid", EXIT_POLICY, "R5 sentence must appear exactly once")

    after_block_end = after_sentinel_pos + len(SENTINEL)
    if after[after_block_end : after_block_end + 1] == "\n":
        after_block_end += 1
    after_suffix = after[after_block_end:]

    if after_suffix != before_suffix:
        die("historical_suffix_changed", EXIT_POLICY, "historical suffix changed")
    if sha256_hex(after_suffix) != sha256_hex(before_suffix):
        die("historical_suffix_changed", EXIT_POLICY, "historical suffix digest changed")

    print(
        json.dumps(
            {
                "ok": True,
                "marker_count": 1,
                "sentinel_count": 1,
                "r5_sentence_count": 1,
                "historical_suffix_preserved": True,
            }
        )
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description="U1R18 PR canonical truth renderer")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("validate-state", help="validate a canonical state file")
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_validate_state)

    p = sub.add_parser("inspect-body", help="inspect a PR body read-only")
    p.add_argument("--body", required=True)
    p.set_defaults(func=cmd_inspect_body)

    p = sub.add_parser("render", help="replace the leading canonical block")
    p.add_argument("--state", required=True)
    p.add_argument("--body", required=True)
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_render)

    p = sub.add_parser("verify-render", help="verify a rendered body against the source")
    p.add_argument("--state", required=True)
    p.add_argument("--before", required=True)
    p.add_argument("--after", required=True)
    p.set_defaults(func=cmd_verify_render)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
