#!/usr/bin/env python3
"""
Mutation applier for workstage-review-gate fixture testing — U1R18-R7-FIX2.

Usage:
  python3 apply-mutation.py <MUTATION_NAME> <temp_dir>

Each mutation modifies fixture JSON files in the temp directory to simulate
a specific policy/protocol violation. If the mutation requires a modified
policy, a policy.json is written to the temp dir.

Mutation categories:
  parent/     — parent review and controller review validation
  bootstrap/  — bootstrap exception validation
  repair/     — repair authorization validation
  report/     — worker report validation (FIX2: null gate_submission_run_id)
  ci/         — CI run and job validation
  submission/ — submission run receipt validation (FIX2)
  controller/ — controller review receipt validation (FIX2)
  infra/      — infrastructure failures (missing/malformed files)
"""

import json
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

# === SHA constants (must match generate-green.py) ===
BOOTSTRAP_HEAD = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"
R7_HEAD = "f3ae89d2caa07930ffda7a84059ecdfb18942e3d"
FIX1_HEAD = "4b7cbe162d0dbf4e660972b2eda3f369588884e3"
FIX2_HEAD = "b7c4f9a8c2d6e103547a9b8c0d2e3f4a5b6c7d8e"
NORMAL_PARENT = "6656ec33d15289ce122f4ba9d1e2db71f260d8b7"
NORMAL_HEAD = "0123456789abcdef0123456789abcdef01234567"
HISTORICAL_HEAD = "9999999999999999999999999999999999999999"
HISTORICAL_PARENT = "8888888888888888888888888888888888888888"
WRONG_SHA = "cafe1234cafe1234cafe1234cafe1234cafe1234"
REPAIR_PARENT = "3c8432951e542879b437b8f7ed4ce2b27ae02429"
REPAIR_HEAD = "fee5d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3"

# === Timestamps ===
HEAD_COMMIT_TS = "2026-08-03T03:00:00Z"
WORKER_REPORT_TS = "2026-08-03T03:10:00Z"
HEAD_REVIEW_TS = "2026-08-03T03:15:00Z"
LATEST_ACCEPT_TS = "2026-08-03T03:20:00Z"
BEFORE_COMMIT_TS = "2026-08-03T02:00:00Z"

# === IDs ===
BOOTSTRAP_REVIEW_ID = 4840817794
REPAIR_REVIEW_ID = 4861858468
QUARANTINED_REVIEW_ID = 4841357081
NORMAL_REVIEW_ID = 4840817795

CI_RUN_ID = 30790400001
GATE_ADVANCE_RUN_ID = 30790400002
SUBMISSION_RUN_ID = 30790400003

REQUIRED_JOBS = ["Swift Build", "Public Audit", "Recipe Validation", "License Validation", "Gitignore Validation"]
FIX3_WORKSTREAM = "U1R18-R7-FIX3"
FIX2_WORKSTREAM = "U1R18-R7-FIX2"
FIX1_WORKSTREAM = "U1R18-R7-FIX1"
GATE1_WORKSTREAM = "U1R18-R8-GATE1"
REPAIR_COMMIT_MSG = "ci: close R10 SCOPE1 audit gaps (U1R18-R10-FIX1-SCOPE1-FIX1)"
REPAIR_COMMIT_MSG = "ci: close workstream review authority gate (U1R18-R7-FIX1)"
REPAIR_CLASSIFICATION = "RED_U1R18_R10_FIX1_SCOPE1_FIX1_RESIDUAL_AUDIT_AND_REPORT_WINDOW_FAILURE"
BOOTSTRAP_CLASSIFICATION = "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"

WORKER_REPORT_COMMENT_ID = 5161887211

CONTROLLER_MARKER = "<!-- macsteam-controller-review:v1 -->"
WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"

POLICY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".github", "workstage-review-gate-policy.json")


def load_json(temp_dir, filename):
    path = os.path.join(temp_dir, filename)
    with open(path) as f:
        return json.load(f)


def save_json(temp_dir, filename, data):
    path = os.path.join(temp_dir, filename)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def load_policy():
    with open(POLICY_PATH) as f:
        return json.load(f)


def get_pr_head(d):
    pr = load_json(d, "pr.json")
    return pr["head"]["sha"]


def is_submission_run(run):
    """A stored submission run is identified by its canonical display_title.

    FIX3 stores the workflow-level run-name in `display_title` while `name`
    carries the static workflow name "Workstream Review Gate".
    """
    if isinstance(run, dict):
        title = str(run.get("display_title", ""))
        if "phase=submission" in title:
            return True
        return "submission" in str(run.get("name", "")).lower()
    return False


def save_policy(temp_dir, policy):
    save_json(temp_dir, "policy.json", policy)


def get_controller_review_body(commit_id, classification="GREEN_U1R18_R6_CONTROLLER_REVIEW_ACCEPTED",
                                decision="accepted", review_id=NORMAL_REVIEW_ID,
                                nx_required=True, ready=False, merge=False, release=False,
                                review_complete=True,
                                wr_comment_id=WORKER_REPORT_COMMENT_ID,
                                sub_run_id=SUBMISSION_RUN_ID):
    json_body = {
        "schema_version": 1,
        "kind": "controller_review",
        "head_sha": commit_id,
        "worker_report_comment_id": wr_comment_id,
        "submission_run_id": sub_run_id,
        "decision": decision,
        "classification": classification,
        "review_complete": review_complete,
        "nx_required_for_next_workstream": nx_required,
        "ready_authorized": ready,
        "merge_authorized": merge,
        "release_authorized": release,
    }
    return CONTROLLER_MARKER + "\n```json\n" + json.dumps(json_body, indent=2) + "\n```\n"


def get_worker_report_body(head_sha, parent_sha, **overrides):
    report = {
        "schema_version": 1,
        "kind": "worker_report",
        "workstream": FIX3_WORKSTREAM,
        "head_sha": head_sha,
        "parent_sha": parent_sha,
        "commit_count": 1,
        "core_ci_run_id": CI_RUN_ID,
        "core_ci_jobs": REQUIRED_JOBS,
        "gate_advance_run_id": GATE_ADVANCE_RUN_ID,
        "gate_submission_run_id": None,
        "stop": True,
        "next_workstream_started": False,
        "ready_performed": False,
        "merge_performed": False,
        "release_performed": False,
    }
    report.update(overrides)
    return WORKER_MARKER + "\n```json\n" + json.dumps(report, indent=2) + "\n```\n"


# === Parent/controller review mutations (based on advance_normal_commented/approved) ===

def m_quarantined_self_review_rejected(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        r["id"] = QUARANTINED_REVIEW_ID
    save_json(d, "reviews.json", reviews)


def m_parent_review_missing(d):
    save_json(d, "reviews.json", [])


def m_parent_review_issue_comment_only(d):
    """Move controller review to comments instead of reviews."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("commit_id") == NORMAL_PARENT:
            body = r.get("body", "")
            comment = {
                "id": 7000000001,
                "user": {"login": "controller"},
                "body": body,
                "created_at": "2026-08-03T02:30:00Z",
                "updated_at": "2026-08-03T02:30:00Z"
            }
            comments = load_json(d, "comments.json")
            if not isinstance(comments, list):
                comments = []
            comments.append(comment)
            save_json(d, "comments.json", comments)
    save_json(d, "reviews.json", [])


def m_parent_review_wrong_head(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        r["commit_id"] = WRONG_SHA
    save_json(d, "reviews.json", reviews)


def m_parent_review_after_child(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("commit_id") == NORMAL_PARENT:
            r["submitted_at"] = "2026-08-03T04:00:00Z"
    save_json(d, "reviews.json", reviews)


def m_parent_review_commented_without_marker(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        r["body"] = "This is a comment without the controller marker."
    save_json(d, "reviews.json", reviews)


def m_parent_review_approved_with_bad_json(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        r["body"] = CONTROLLER_MARKER + "\n```json\n{bad json here\n```\n"
    save_json(d, "reviews.json", reviews)


def m_latest_rejected_overrides_old_green(d):
    reviews = load_json(d, "reviews.json")
    bad_review = {
        "id": 4840817800,
        "user": {"login": "controller"},
        "commit_id": NORMAL_PARENT,
        "state": "COMMENTED",
        "body": CONTROLLER_MARKER + "\n```json\n" + json.dumps({
            "schema_version": 1, "kind": "controller_review",
            "head_sha": NORMAL_PARENT, "decision": "rejected",
            "classification": "RED_U1R18_R7_FAIL_OPEN",
            "review_complete": True, "nx_required_for_next_workstream": True,
            "ready_authorized": False, "merge_authorized": False,
            "release_authorized": False
        }, indent=2) + "\n```\n",
        "submitted_at": LATEST_ACCEPT_TS
    }
    reviews.append(bad_review)
    save_json(d, "reviews.json", reviews)


def m_selected_changes_requested(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("commit_id") == NORMAL_PARENT:
            r["state"] = "CHANGES_REQUESTED"
    save_json(d, "reviews.json", reviews)


def m_selected_dismissed(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("commit_id") == NORMAL_PARENT:
            r["state"] = "DISMISSED"
    save_json(d, "reviews.json", reviews)


def m_controller_json_head_mismatch(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            body = r["body"]
            body = body.replace(NORMAL_PARENT, WRONG_SHA)
            r["body"] = body
    save_json(d, "reviews.json", reviews)


def m_controller_nx_required_false(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["nx_required_for_next_workstream"] = False
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_ready_true(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["ready_authorized"] = True
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_merge_true(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["merge_authorized"] = True
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_release_true(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["release_authorized"] = True
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_review_complete_false(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["review_complete"] = False
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_classification_not_green(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["classification"] = "RED_U1R18_R7_SOME_FAILURE"
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_marker_duplicated_in_body(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            r["body"] = CONTROLLER_MARKER + "\n" + CONTROLLER_MARKER + r["body"]
    save_json(d, "reviews.json", reviews)


def m_controller_json_blocks_duplicated(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            r["body"] = r["body"] + "\n```json\n{}\n```\n"
    save_json(d, "reviews.json", reviews)


def m_report_edited_after_review(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["updated_at"] = "2026-08-03T04:00:00Z"
    save_json(d, "comments.json", comments)


# === Bootstrap mutations (based on advance_bootstrap) ===

def m_bootstrap_policy_green_without_body_evidence(d):
    policy = load_policy()
    policy["bootstrap"]["classification"] = "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"
    save_policy(d, policy)
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == BOOTSTRAP_REVIEW_ID:
            r["body"] = "Bootstrap review without classification in body. Just GREEN_"
    save_json(d, "reviews.json", reviews)


def m_bootstrap_wrong_review_id(d):
    policy = load_policy()
    policy["bootstrap"]["controller_review_id"] = 9999999999
    save_policy(d, policy)


def m_bootstrap_wrong_commit(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == BOOTSTRAP_REVIEW_ID:
            r["commit_id"] = WRONG_SHA
    save_json(d, "reviews.json", reviews)


def m_bootstrap_wrong_classification(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == BOOTSTRAP_REVIEW_ID:
            r["body"] = "Bootstrap review. Classification: GREEN_U1R18_DIFFERENT_CLASSIFICATION"
    save_json(d, "reviews.json", reviews)


def m_bootstrap_wrong_child(d):
    pr = load_json(d, "pr.json")
    pr["head"]["sha"] = WRONG_SHA
    save_json(d, "pr.json", pr)
    commit = load_json(d, "commit_HEAD.json")
    commit["sha"] = WRONG_SHA
    commit["parents"] = [{"sha": BOOTSTRAP_HEAD}]
    save_json(d, "commit_HEAD.json", commit)


def m_bootstrap_reused_after_r7(d):
    policy = load_policy()
    policy["bootstrap"]["only_child_head"] = NORMAL_HEAD
    save_policy(d, policy)
    pr = load_json(d, "pr.json")
    pr["head"]["sha"] = NORMAL_HEAD
    save_json(d, "pr.json", pr)
    commit = load_json(d, "commit_HEAD.json")
    commit["sha"] = NORMAL_HEAD
    commit["parents"] = [{"sha": BOOTSTRAP_HEAD}]
    save_json(d, "commit_HEAD.json", commit)


# === Repair mutations (based on advance_repair) ===

def m_repair_wrong_review_id(d):
    policy = load_policy()
    policy["repair_authorization"]["review_id"] = 9999999999
    save_policy(d, policy)


def m_repair_wrong_parent(d):
    policy = load_policy()
    policy["repair_authorization"]["parent_sha"] = WRONG_SHA
    save_policy(d, policy)


def m_repair_wrong_classification(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            r["body"] = r["body"].replace(REPAIR_CLASSIFICATION, "RED_U1R18_DIFFERENT_REASON")
    save_json(d, "reviews.json", reviews)


def m_repair_wrong_commit_message(d):
    commit = load_json(d, "commit_HEAD.json")
    commit["commit"]["message"] = "wrong commit message\n\nWorkstream: U1R18-R7-FIX1"
    save_json(d, "commit_HEAD.json", commit)


def m_repair_wrong_workstream_trailer(d):
    commit = load_json(d, "commit_HEAD.json")
    msg = commit["commit"]["message"]
    msg = re.sub(r"^Workstream:.*$", "Workstream: U1R18-R7-FIX9", msg, flags=re.MULTILINE)
    commit["commit"]["message"] = msg
    save_json(d, "commit_HEAD.json", commit)


def m_repair_wrong_decision(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["decision"] = "approved"
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_repair_wrong_review_state(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            r["state"] = "APPROVED"
    save_json(d, "reviews.json", reviews)


def m_repair_malformed_json(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            r["body"] = CONTROLLER_MARKER + "\n```json\n{bad json\n```\n"
    save_json(d, "reviews.json", reviews)


def m_repair_marker_duplicated(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            r["body"] = CONTROLLER_MARKER + "\n" + CONTROLLER_MARKER + r["body"]
    save_json(d, "reviews.json", reviews)


def m_repair_json_head_mismatch(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["head_sha"] = WRONG_SHA
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_repair_review_incomplete(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["review_complete"] = False
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_repair_nx_required_false(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["nx_required_for_next_workstream"] = False
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_repair_unsafe_authorization(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            json_data, _, _ = parse_json_block_local(r["body"], CONTROLLER_MARKER)
            if json_data:
                json_data["merge_authorized"] = True
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_repair_review_after_child(d):
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            r["submitted_at"] = "2026-08-03T04:00:00Z"
    save_json(d, "reviews.json", reviews)


def m_repair_forbidden_path(d):
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("unknown/path/file.txt")
    save_json(d, "files.json", files)


def m_repair_production_source_changed(d):
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("Sources/MacSteam/SomeFile.swift")
    save_json(d, "files.json", files)


def m_repair_merge_commit(d):
    commit = load_json(d, "commit_HEAD.json")
    commit["parents"].append({"sha": WRONG_SHA})
    save_json(d, "commit_HEAD.json", commit)


def m_repair_reused_after_fix1(d):
    policy = load_policy()
    policy["repair_authorization"]["parent_sha"] = WRONG_SHA
    save_policy(d, policy)


def m_repair_quarantined_review_used(d):
    policy = load_policy()
    policy["repair_authorization"]["review_id"] = QUARANTINED_REVIEW_ID
    save_policy(d, policy)
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("id") == REPAIR_REVIEW_ID:
            r["id"] = QUARANTINED_REVIEW_ID
    save_json(d, "reviews.json", reviews)


# === Repair scope mutations (two-tier authority) ===

def _scope_policy(d, scope_mutator):
    policy = load_policy()
    scope_mutator(policy["repair_authorization"])
    save_policy(d, policy)


def m_repair_scope_missing(d):
    policy = load_policy()
    policy["repair_authorization"].pop("allowed_exact_paths", None)
    policy["repair_authorization"].pop("allowed_path_prefixes", None)
    save_policy(d, policy)


def m_repair_scope_wrong_type_exact(d):
    _scope_policy(d, lambda ra: ra.__setitem__("allowed_exact_paths", "not-a-list"))


def m_repair_scope_wrong_type_prefix(d):
    _scope_policy(d, lambda ra: ra.__setitem__("allowed_path_prefixes", 42))


def m_repair_scope_empty_entry(d):
    _scope_policy(d, lambda ra: ra["allowed_exact_paths"].append(""))


def m_repair_scope_duplicate(d):
    _scope_policy(d, lambda ra: ra["allowed_exact_paths"].append(
        ra["allowed_exact_paths"][0]))


def m_repair_scope_absolute(d):
    _scope_policy(d, lambda ra: ra["allowed_exact_paths"].append("/etc/passwd"))


def m_repair_scope_traversal(d):
    _scope_policy(d, lambda ra: ra["allowed_exact_paths"].append(
        "scripts/../../secret"))


def m_repair_scope_prefix_no_slash(d):
    _scope_policy(d, lambda ra: ra["allowed_path_prefixes"].append(
        "scripts/workstage-review-gate-fixtures"))


def m_repair_scope_outside_envelope(d):
    _scope_policy(d, lambda ra: ra["allowed_exact_paths"].append(
        "docs/UNRELATED.md"))


def m_repair_scope_sources_declared(d):
    _scope_policy(d, lambda ra: ra["allowed_path_prefixes"].append("Sources/"))


def m_repair_scope_tests_declared(d):
    _scope_policy(d, lambda ra: ra["allowed_path_prefixes"].append("Tests/"))


def m_repair_scope_front_file_omitted(d):
    # A safe-envelope file (u1r18-pr-truth.py) changed but omitted from the
    # declared scope.
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("scripts/u1r18-pr-truth.py")
    save_json(d, "files.json", files)


def m_repair_scope_gate1_changes_truth_py(d):
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("scripts/u1r18-pr-truth.py")
    save_json(d, "files.json", files)


def m_repair_scope_gate1_changes_truth_fixtures(d):
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("scripts/u1r18-pr-truth-fixtures/red/state-child.json")
    save_json(d, "files.json", files)


def m_repair_scope_tier_a_doc_denied(d):
    # A §9 canonical doc lives in the Tier A safe envelope but is NOT declared
    # in the SCOPE1 repair Tier B scope. Tier B is the binding constraint, so
    # a changed file there must be rejected (repair_forbidden_path), even
    # though Tier A would otherwise admit it.
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("docs/ARCHITECTURE.md")
    save_json(d, "files.json", files)


def m_repair_scope_old_r8_review_id(d):
    policy = load_policy()
    policy["repair_authorization"]["review_id"] = 4849925632
    save_policy(d, policy)


def m_repair_scope_r9_rejects_gate_path(d):
    # Under the r9 fixture-local policy (admits only R9 truth path), a gate-only
    # file change must fail.
    files = load_json(d, "files.json") if os.path.exists(os.path.join(d, "files.json")) else []
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("scripts/workstage-review-gate.py")
    save_json(d, "files.json", files)


# === Worker report mutations (based on submission_historical_reports) ===

def m_report_missing(d):
    save_json(d, "comments.json", [])


def m_report_malformed_current_head(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            body = c["body"]
            idx = body.find(WORKER_MARKER)
            rest = body[idx + len(WORKER_MARKER):]
            body = WORKER_MARKER + "\n```json\n{broken json\n```\n"
            c["body"] = body
    save_json(d, "comments.json", comments)


def m_report_marker_duplicated(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["body"] = WORKER_MARKER + "\n" + WORKER_MARKER + c["body"]
    save_json(d, "comments.json", comments)


def m_report_json_block_duplicated(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            idx = c["body"].find(WORKER_MARKER)
            rest = c["body"][idx:]
            c["body"] = c["body"][:idx] + WORKER_MARKER + "\n```json\n{}\n```\n" + rest
    save_json(d, "comments.json", comments)


def m_report_inline(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["path"] = "SomeFile.swift"
            c["position"] = 1
    save_json(d, "comments.json", comments)


def m_report_reply(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["in_reply_to_id"] = 5161887199
    save_json(d, "comments.json", comments)


def m_duplicate_current_head_reports(d):
    comments = load_json(d, "comments.json")
    head = get_pr_head(d)
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data and json_data.get("head_sha") == head:
                new_comment = dict(c)
                new_comment["id"] = 5161887299
                comments.append(new_comment)
                break
    save_json(d, "comments.json", comments)


def m_historical_reports_do_not_conflict(d):
    comments = load_json(d, "comments.json")
    bad_comment = {
        "id": 5161887298,
        "user": {"login": "macsteam-dev"},
        "body": WORKER_MARKER + "\n" + WORKER_MARKER + "\n```json\n{}\n```\n",
        "created_at": "2026-08-02T12:00:00Z",
        "updated_at": "2026-08-02T12:00:00Z"
    }
    comments.append(bad_comment)
    save_json(d, "comments.json", comments)


def m_report_head_mismatch(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["head_sha"] = WRONG_SHA
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_parent_mismatch(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["parent_sha"] = WRONG_SHA
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_commit_count_invalid(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["commit_count"] = 2
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_workstream_mismatch(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["workstream"] = "U1R18-R7"
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_head_commit_message_missing(d):
    commit = load_json(d, "commit_HEAD.json")
    commit["commit"]["message"] = ""
    save_json(d, "commit_HEAD.json", commit)


def m_head_workstream_trailer_missing(d):
    commit = load_json(d, "commit_HEAD.json")
    msg = commit["commit"]["message"]
    msg = re.sub(r"\n\nWorkstream: [^\n]*", "", msg, flags=re.MULTILINE)
    commit["commit"]["message"] = msg
    save_json(d, "commit_HEAD.json", commit)


def m_head_workstream_trailer_duplicated(d):
    commit = load_json(d, "commit_HEAD.json")
    msg = commit["commit"]["message"]
    msg += "\nWorkstream: U1R18-R7-FIX3"
    commit["commit"]["message"] = msg
    save_json(d, "commit_HEAD.json", commit)


def m_head_workstream_trailer_invalid(d):
    commit = load_json(d, "commit_HEAD.json")
    msg = commit["commit"]["message"]
    msg = re.sub(r"^Workstream:.*$", "Workstream: U1R18/R8", msg, flags=re.MULTILINE)
    commit["commit"]["message"] = msg
    save_json(d, "commit_HEAD.json", commit)


# === FIX1: Replay isolation mutations (base: submission_exact_comment_id) ===

def m_replay_malformed_marker_at_or_after_head(d):
    """Current-window marker comment with no JSON fence → block_count 0."""
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["body"] = WORKER_MARKER + "\n\nNo fence here.\n"
    save_json(d, "comments.json", comments)


def m_replay_malformed_json_at_or_after_head(d):
    """Current-window marker comment with broken JSON → malformed report."""
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["body"] = WORKER_MARKER + "\n```json\n{broken json\n```\n"
    save_json(d, "comments.json", comments)


def m_replay_historical_marker_missing_timestamp(d):
    """A marker-bearing comment (before HEAD) with no created_at → infra."""
    comments = load_json(d, "comments.json")
    bad = {
        "id": 5172949100,
        "user": {"login": "macsteam-dev"},
        "body": WORKER_MARKER + "\n```json\n{}\n```\n",
        "created_at": None,
        "updated_at": None,
        "path": None,
        "position": None,
        "in_reply_to_id": None,
    }
    comments.insert(0, bad)
    save_json(d, "comments.json", comments)


def m_replay_historical_marker_malformed_timestamp(d):
    """A marker-bearing comment (before HEAD) with malformed created_at."""
    comments = load_json(d, "comments.json")
    bad = {
        "id": 5172949101,
        "user": {"login": "macsteam-dev"},
        "body": WORKER_MARKER + "\n```json\n{}\n```\n",
        "created_at": "not-a-date",
        "updated_at": "not-a-date",
        "path": None,
        "position": None,
        "in_reply_to_id": None,
    }
    comments.insert(0, bad)
    save_json(d, "comments.json", comments)


def m_replay_duplicate_valid_current_head_reports(d):
    """Two valid current-HEAD worker reports → duplicate_current_head_reports."""
    comments = load_json(d, "comments.json")
    head = get_pr_head(d)
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data and json_data.get("head_sha") == head:
                dup = dict(c)
                dup["id"] = 5161887299
                comments.append(dup)
                break
    save_json(d, "comments.json", comments)


def m_replay_selected_exact_report_malformed(d):
    """The exact selected comment (comment.json) is malformed → selected guard."""
    comment = load_json(d, "comment.json")
    comment["body"] = WORKER_MARKER + "\n```json\n{bad\n```\n"
    save_json(d, "comment.json", comment)


def m_report_stop_false(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["stop"] = False
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_next_workstream_true(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["next_workstream_started"] = True
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_ready_true(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["ready_performed"] = True
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_merge_true(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["merge_performed"] = True
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_release_true(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["release_performed"] = True
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_before_commit(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            c["created_at"] = BEFORE_COMMIT_TS
            c["updated_at"] = BEFORE_COMMIT_TS
    save_json(d, "comments.json", comments)


def m_report_bool_used_as_integer(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["core_ci_run_id"] = True
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_duplicate_ci_jobs(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["core_ci_jobs"] = REQUIRED_JOBS + ["Swift Build"]
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_invalid_array_item(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["core_ci_jobs"] = REQUIRED_JOBS[:4] + [123]
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_extra_property(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["unexpected_field"] = "should_not_be_here"
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


# === CI mutations (based on submission_historical_reports) ===

def m_ci_run_missing(d):
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["core_ci_run_id"] = 99999
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_ci_run_wrong_head(d):
    runs = load_json(d, "runs.json")
    if isinstance(runs, dict):
        runs = runs.get("workflow_runs", [])
    for run in runs:
        if run.get("name") == "CI":
            run["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", {"workflow_runs": runs})


def m_ci_run_wrong_workflow(d):
    runs = load_json(d, "runs.json")
    if isinstance(runs, dict):
        runs = runs.get("workflow_runs", [])
    for run in runs:
        if run.get("name") == "CI":
            run["name"] = "Other Workflow"
    save_json(d, "runs.json", {"workflow_runs": runs})


def m_ci_run_incomplete(d):
    runs = load_json(d, "runs.json")
    if isinstance(runs, dict):
        runs = runs.get("workflow_runs", [])
    for run in runs:
        if run.get("name") == "CI":
            run["status"] = "in_progress"
    save_json(d, "runs.json", {"workflow_runs": runs})


def m_ci_run_failed(d):
    runs = load_json(d, "runs.json")
    if isinstance(runs, dict):
        runs = runs.get("workflow_runs", [])
    for run in runs:
        if run.get("name") == "CI":
            run["conclusion"] = "failure"
    save_json(d, "runs.json", {"workflow_runs": runs})


def m_ci_job_missing(d):
    jobs = load_json(d, "jobs.json")
    if isinstance(jobs, dict):
        jobs = jobs.get("jobs", [])
    jobs = [j for j in jobs if j.get("name") != "Gitignore Validation"]
    save_json(d, "jobs.json", {"jobs": jobs})


def m_ci_job_failed(d):
    jobs = load_json(d, "jobs.json")
    if isinstance(jobs, dict):
        jobs = jobs.get("jobs", [])
    for j in jobs:
        if j.get("name") == "Swift Build":
            j["conclusion"] = "failure"
    save_json(d, "jobs.json", {"jobs": jobs})


def m_ci_job_duplicate(d):
    jobs = load_json(d, "jobs.json")
    if isinstance(jobs, dict):
        jobs = jobs.get("jobs", [])
    jobs.append({"name": "Swift Build", "conclusion": "success", "status": "completed",
                 "run_id": CI_RUN_ID})
    save_json(d, "jobs.json", {"jobs": jobs})


# === PR state / policy binding mutations ===

def m_repository_mismatch(d):
    pr = load_json(d, "pr.json")
    pr["head"]["repo"]["full_name"] = "wrong/repo"
    pr["base"]["repo"]["full_name"] = "wrong/repo"
    save_json(d, "pr.json", pr)


def m_pr_number_mismatch(d):
    pr = load_json(d, "pr.json")
    pr["number"] = 999
    save_json(d, "pr.json", pr)


def m_head_branch_mismatch(d):
    pr = load_json(d, "pr.json")
    pr["head"]["ref"] = "wrong-branch"
    save_json(d, "pr.json", pr)


def m_base_branch_mismatch(d):
    pr = load_json(d, "pr.json")
    pr["base"]["ref"] = "wrong-base"
    save_json(d, "pr.json", pr)


def m_pr_closed(d):
    pr = load_json(d, "pr.json")
    pr["state"] = "CLOSED"
    save_json(d, "pr.json", pr)


def m_pr_not_draft(d):
    pr = load_json(d, "pr.json")
    pr["draft"] = False
    save_json(d, "pr.json", pr)


def m_pr_merged(d):
    pr = load_json(d, "pr.json")
    pr["merged"] = True
    save_json(d, "pr.json", pr)


def m_pr_not_mergeable(d):
    pr = load_json(d, "pr.json")
    pr["mergeable"] = "CONFLICTING"
    save_json(d, "pr.json", pr)


def m_expected_head_invalid(d):
    pr = load_json(d, "pr.json")
    bad_sha = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
    pr["head"]["sha"] = bad_sha
    pr["number"] = 999
    save_json(d, "pr.json", pr)


def m_merge_commit_rejected(d):
    commit = load_json(d, "commit_HEAD.json")
    commit["parents"].append({"sha": WRONG_SHA})
    save_json(d, "commit_HEAD.json", commit)


# === Infrastructure mutations ===

def m_policy_missing(d):
    if os.path.exists(os.path.join(d, "policy.json")):
        os.remove(os.path.join(d, "policy.json"))


def m_policy_malformed(d):
    with open(os.path.join(d, "policy.json"), "w") as f:
        f.write("{invalid json}")


def m_schema_missing(d):
    pass  # handled by test harness not providing schema


def m_fixture_missing_reviews(d):
    path = os.path.join(d, "reviews.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_pr(d):
    path = os.path.join(d, "pr.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_commit(d):
    path = os.path.join(d, "commit_HEAD.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_comments(d):
    path = os.path.join(d, "comments.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_runs(d):
    path = os.path.join(d, "runs.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_jobs(d):
    path = os.path.join(d, "jobs.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_json_malformed(d):
    with open(os.path.join(d, "reviews.json"), "w") as f:
        f.write("{broken")


def m_pagination_parse_failure(d):
    with open(os.path.join(d, "comments.json"), "w") as f:
        f.write("{broken")


def m_pagination_page_type_invalid(d):
    save_json(d, "reviews.json", {"not_a_list": True})


def m_pagination_duplicate_id(d):
    reviews = load_json(d, "reviews.json")
    if len(reviews) > 0:
        reviews.append(dict(reviews[0]))
    save_json(d, "reviews.json", reviews)


def m_timestamp_malformed(d):
    commit = load_json(d, "commit_HEAD.json")
    commit["commit"]["committer"]["date"] = "not-a-date"
    save_json(d, "commit_HEAD.json", commit)


def m_commit_parent_missing(d):
    commit = load_json(d, "commit_HEAD.json")
    commit["parents"] = []
    save_json(d, "commit_HEAD.json", commit)


def m_mergeable_unknown(d):
    pr = load_json(d, "pr.json")
    pr["mergeable"] = None
    save_json(d, "pr.json", pr)


def m_api_404_pr(d):
    path = os.path.join(d, "pr.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_commit(d):
    path = os.path.join(d, "commit_HEAD.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_comments(d):
    path = os.path.join(d, "comments.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_reviews(d):
    path = os.path.join(d, "reviews.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_runs(d):
    path = os.path.join(d, "runs.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_jobs(d):
    path = os.path.join(d, "jobs.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_submission_runs(d):
    """submission-runs.json missing (API 404 for submission runs endpoint)."""
    path = os.path.join(d, "submission-runs.json")
    if os.path.exists(path):
        os.remove(path)


def m_api_404_submission_jobs(d):
    """submission-jobs.json missing (API 404 for submission jobs endpoint)."""
    path = os.path.join(d, "submission-jobs.json")
    if os.path.exists(path):
        os.remove(path)


# === FIX2: Submission run receipt mutations ===

def m_submission_run_wrong_head(d):
    """Submission run head_sha != expected head (targets the HEAD run)."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    head = get_pr_head(d)
    for run in runs_list:
        if run.get("head_sha") == head:
            run["head_sha"] = WRONG_SHA
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_wrong_branch(d):
    """Submission run head_branch != expected branch."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["head_branch"] = "wrong-branch"
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_wrong_event(d):
    """Submission run event != workflow_dispatch."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["event"] = "push"
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_wrong_phase_in_name(d):
    """Submission run display_title does not encode phase=submission."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        title = run.get("display_title", "")
        if "phase=submission" in title:
            run["display_title"] = title.replace("phase=submission", "phase=review")
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_wrong_pr_in_name(d):
    """Submission run display_title does not encode correct PR number."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        title = run.get("display_title", "")
        if "PR=2" in title:
            run["display_title"] = title.replace("PR=2", "PR=99")
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_wrong_report_id_in_name(d):
    """Submission run display_title does not encode correct worker report comment ID."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        title = run.get("display_title", "")
        if f"REPORT={WORKER_REPORT_COMMENT_ID}" in title:
            run["display_title"] = title.replace(f"REPORT={WORKER_REPORT_COMMENT_ID}", "REPORT=9999999999")
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_wrong_head_in_name(d):
    """Submission run display_title does not encode correct HEAD SHA (targets HEAD run)."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    head = get_pr_head(d)
    for run in runs_list:
        title = run.get("display_title", "")
        if f"HEAD={head}" in title:
            run["display_title"] = title.replace(f"HEAD={head}", f"HEAD={WRONG_SHA}")
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_attempt_gt_one(d):
    """Submission run run_attempt > 1."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["run_attempt"] = 2
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_incomplete(d):
    """Submission run status != completed."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["status"] = "in_progress"
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_run_failed(d):
    """Submission run conclusion != success."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["conclusion"] = "failure"
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_gate_job_missing(d):
    """Submission Gate job missing from submission run jobs."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    jobs_list = [j for j in jobs_list if j.get("name") != "Submission Gate"]
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_submission_gate_job_failed(d):
    """Submission Gate job conclusion != success."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    for j in jobs_list:
        if j.get("name") == "Submission Gate":
            j["conclusion"] = "failure"
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_submission_gate_job_skipped(d):
    """Submission Gate job was skipped."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    for j in jobs_list:
        if j.get("name") == "Submission Gate":
            j["conclusion"] = "skipped"
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_submission_gate_job_cancelled(d):
    """Submission Gate job was cancelled."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    for j in jobs_list:
        if j.get("name") == "Submission Gate":
            j["conclusion"] = "cancelled"
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_submission_gate_job_duplicate(d):
    """Multiple Submission Gate jobs in submission run."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    for j in jobs_list:
        if j.get("name") == "Submission Gate":
            jobs_list.append(dict(j))
            break
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_receipt_submission_job_wrong_name(d):
    """Submission run gate job renamed to a non-canonical name."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    for j in jobs_list:
        if j.get("name") == "Submission Gate":
            j["name"] = "Review Gate"
            break
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_receipt_wrong_workflow_path(d):
    """Submission run workflow path wrong (or points at another workflow)."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        run["path"] = ".github/workflows/ci.yml"
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_report_created_after_submission_run(d):
    """Worker report comment created at > submission run started at."""
    submission_started = "2026-08-03T02:30:00Z"
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["started_at"] = submission_started
            run["created_at"] = submission_started
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})

    # Also make the worker report comment created_after the submission run start
    comments = load_json(d, "comments.json")
    if isinstance(comments, list):
        for c in comments:
            if WORKER_MARKER in (c.get("body", "")):
                c["created_at"] = "2026-08-03T02:40:00Z"
                c["updated_at"] = "2026-08-03T02:40:00Z"
    save_json(d, "comments.json", comments)


def m_submission_completed_after_review(d):
    """Submission run completed_at > controller review submitted_at."""
    review_ts = "2026-08-03T03:00:00Z"
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["completed_at"] = "2026-08-03T05:00:00Z"
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})

    # Also set controller review submitted_at before the submission completed
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if CONTROLLER_MARKER in (r.get("body", "")):
            r["submitted_at"] = review_ts
    save_json(d, "reviews.json", reviews)


def m_submission_run_wrong_id(d):
    """Controller review references a non-existent submission run ID."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["submission_run_id"] = 8888888888
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_report_submission_run_numeric(d):
    """Worker report gate_submission_run_id is a number (not null)."""
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["gate_submission_run_id"] = 12345
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_submission_run_string(d):
    """Worker report gate_submission_run_id is a string (not null)."""
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["gate_submission_run_id"] = "30790400003"
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_report_submission_run_missing(d):
    """Worker report missing gate_submission_run_id field."""
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                del json_data["gate_submission_run_id"]
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_controller_worker_report_comment_id_missing(d):
    """Controller review missing worker_report_comment_id."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                del json_data["worker_report_comment_id"]
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_submission_run_id_missing(d):
    """Controller review missing submission_run_id."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                del json_data["submission_run_id"]
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_worker_report_comment_id_zero(d):
    """Controller review worker_report_comment_id = 0."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["worker_report_comment_id"] = 0
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_submission_run_id_zero(d):
    """Controller review submission_run_id = 0."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["submission_run_id"] = 0
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_worker_report_comment_id_string(d):
    """Controller review worker_report_comment_id is a string."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["worker_report_comment_id"] = "5161887211"
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_submission_run_id_string(d):
    """Controller review submission_run_id is a string."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["submission_run_id"] = "30790400003"
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_receipt_wrong_comment_id(d):
    """Controller review references wrong worker_report_comment_id."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["worker_report_comment_id"] = 9999999999
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_controller_receipt_wrong_submission_run_id(d):
    """Controller review references wrong submission_run_id."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        body = r.get("body", "")
        if CONTROLLER_MARKER in body:
            json_data, _, _ = parse_json_block_local(body, CONTROLLER_MARKER)
            if json_data:
                json_data["submission_run_id"] = 8888888888
                r["body"] = rebuild_body(json_data)
    save_json(d, "reviews.json", reviews)


def m_report_gate_submission_run_id_non_null(d):
    """Worker report gate_submission_run_id is non-null (should be null pre-submission)."""
    comments = load_json(d, "comments.json")
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
            json_data, _, _ = parse_json_block_local(c["body"], WORKER_MARKER)
            if json_data:
                json_data["gate_submission_run_id"] = SUBMISSION_RUN_ID
                c["body"] = rebuild_worker_body(json_data)
    save_json(d, "comments.json", comments)


def m_submission_run_id_mismatch(d):
    """Submission run ID in API response doesn't match referenced ID."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    for run in runs_list:
        if is_submission_run(run):
            run["id"] = 7777777777
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_runs_json_malformed(d):
    """Submission runs JSON is malformed."""
    path = os.path.join(d, "submission-runs.json")
    if os.path.exists(path):
        with open(path, "w") as f:
            f.write("{broken")


def m_submission_jobs_json_malformed(d):
    """Submission jobs JSON is malformed."""
    path = os.path.join(d, "submission-jobs.json")
    if os.path.exists(path):
        with open(path, "w") as f:
            f.write("{broken")


def m_submission_runs_page_type_invalid(d):
    """Submission runs API returns non-list page type."""
    save_json(d, "submission-runs.json", {"not_a_list": True})


def m_submission_runs_duplicate_id(d):
    """Duplicate submission run ID in submission-runs.json."""
    runs = load_json(d, "submission-runs.json")
    runs_list = runs.get("workflow_runs", []) if isinstance(runs, dict) else runs
    if len(runs_list) > 0:
        runs_list.append(dict(runs_list[0]))
    save_json(d, "submission-runs.json", {"workflow_runs": runs_list})


def m_submission_job_id_non_integer(d):
    """Submission job has non-integer id field."""
    jobs = load_json(d, "submission-jobs.json")
    jobs_list = jobs.get("jobs", []) if isinstance(jobs, dict) else jobs
    for j in jobs_list:
        j["id"] = "not_an_integer"
    save_json(d, "submission-jobs.json", {"jobs": jobs_list})


def m_fixture_missing_submission_runs(d):
    """submission-runs.json missing."""
    path = os.path.join(d, "submission-runs.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_submission_jobs(d):
    """submission-jobs.json missing."""
    path = os.path.join(d, "submission-jobs.json")
    if os.path.exists(path):
        os.remove(path)


def m_fixture_missing_submission_comment(d):
    """comment.json (single comment lookup) missing."""
    path = os.path.join(d, "comment.json")
    if os.path.exists(path):
        os.remove(path)


# === Helper functions ===

def parse_json_block_local(body, marker):
    if not body:
        return None, 0, 0
    marker_count = body.count(marker)
    block_count = body.count("```json")
    idx = body.find(marker)
    if idx == -1:
        return None, marker_count, block_count
    rest = body[idx + len(marker):]
    match = re.search(r'```json\s*\n(.*?)\n```', rest, re.DOTALL)
    if not match:
        return None, marker_count, block_count
    try:
        return json.loads(match.group(1)), marker_count, block_count
    except (json.JSONDecodeError, ValueError):
        return None, marker_count, block_count


def rebuild_body(json_data, marker=CONTROLLER_MARKER):
    return marker + "\n```json\n" + json.dumps(json_data, indent=2) + "\n```\n"


def rebuild_worker_body(json_data):
    return rebuild_body(json_data, WORKER_MARKER)


# === Workflow YAML mutations (FIX3 §12/§13) ===

def load_workflow(d):
    path = os.path.join(d, "workflow.yml")
    if not os.path.exists(path):
        raise ValueError(f"workflow.yml missing in {d}")
    with open(path) as f:
        return yaml.safe_load(f)


def save_workflow(d, doc):
    with open(os.path.join(d, "workflow.yml"), "w") as f:
        yaml.safe_dump(doc, f, sort_keys=False)


def wf_triggers(doc):
    for key in (True, "on", "On", "ON"):
        if isinstance(doc, dict) and key in doc:
            return doc[key]
    return {}


def m_workflow_worker_report_input_missing(d):
    doc = load_workflow(d)
    inputs = wf_triggers(doc).get("workflow_dispatch", {}).get("inputs", {})
    if "worker_report_comment_id" in inputs:
        del inputs["worker_report_comment_id"]
    save_workflow(d, doc)


def m_workflow_worker_report_input_optional(d):
    doc = load_workflow(d)
    inputs = wf_triggers(doc).get("workflow_dispatch", {}).get("inputs", {})
    if isinstance(inputs.get("worker_report_comment_id"), dict):
        inputs["worker_report_comment_id"]["required"] = False
    save_workflow(d, doc)


def m_workflow_submission_cli_arg_missing(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job in jobs.values():
        if job.get("name") == "Submission Gate":
            steps = job.get("steps", [])
            for step in steps:
                if isinstance(step.get("run"), str):
                    step["run"] = step["run"].replace(
                        " --worker-report-comment-id ${{ inputs.worker_report_comment_id }}", "")
    save_workflow(d, doc)


def m_workflow_submission_cli_arg_hardcoded(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job in jobs.values():
        if job.get("name") == "Submission Gate":
            steps = job.get("steps", [])
            for step in steps:
                if isinstance(step.get("run"), str):
                    step["run"] = step["run"].replace(
                        "${{ inputs.worker_report_comment_id }}", "1234567890")
    save_workflow(d, doc)


def m_workflow_review_cli_arg_missing(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job in jobs.values():
        if job.get("name") == "Review Gate":
            steps = job.get("steps", [])
            for step in steps:
                if isinstance(step.get("run"), str):
                    step["run"] = step["run"].replace(
                        " --worker-report-comment-id ${{ inputs.worker_report_comment_id }}", "")
    save_workflow(d, doc)


def m_workflow_run_name_missing(d):
    doc = load_workflow(d)
    doc.pop("run-name", None)
    save_workflow(d, doc)


def m_workflow_run_name_missing_phase(d):
    doc = load_workflow(d)
    if isinstance(doc.get("run-name"), str):
        doc["run-name"] = doc["run-name"].replace(" / phase=${{ inputs.phase }}", "")
    save_workflow(d, doc)


def m_workflow_run_name_missing_pr(d):
    doc = load_workflow(d)
    if isinstance(doc.get("run-name"), str):
        doc["run-name"] = doc["run-name"].replace(" / PR=${{ inputs.pr_number }}", "")
    save_workflow(d, doc)


def m_workflow_run_name_missing_head(d):
    doc = load_workflow(d)
    if isinstance(doc.get("run-name"), str):
        doc["run-name"] = doc["run-name"].replace(" / HEAD=${{ inputs.expected_head }}", "")
    save_workflow(d, doc)


def m_workflow_run_name_missing_report(d):
    doc = load_workflow(d)
    if isinstance(doc.get("run-name"), str):
        doc["run-name"] = doc["run-name"].replace(" / REPORT=${{ inputs.worker_report_comment_id }}", "")
    save_workflow(d, doc)


def m_workflow_submission_job_wrong_name(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job in jobs.values():
        if job.get("name") == "Submission Gate":
            job["name"] = "Manual Gate"
    save_workflow(d, doc)


def m_workflow_submission_job_duplicate(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job_id, job in list(jobs.items()):
        if job.get("name") == "Submission Gate":
            jobs[job_id + "_dup"] = {"name": "Submission Gate", "if": job.get("if"),
                                     "steps": job.get("steps")}
            break
    save_workflow(d, doc)


def m_workflow_generic_manual_job_restored(d):
    doc = load_workflow(d)
    doc.setdefault("jobs", {})["manual"] = {
        "name": "Manual Gate",
        "if": "github.event_name == 'workflow_dispatch'",
        "steps": [{"run": "echo manual"}],
    }
    save_workflow(d, doc)


def m_workflow_submission_condition_too_broad(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job in jobs.values():
        if job.get("name") == "Submission Gate":
            job["if"] = "github.event_name == 'workflow_dispatch'"
    save_workflow(d, doc)


def m_workflow_checkout_expected_head_missing(d):
    doc = load_workflow(d)
    jobs = doc.get("jobs", {})
    for job in jobs.values():
        if job.get("name") in ("Submission Gate", "Review Gate"):
            steps = job.get("steps", [])
            for step in steps:
                if isinstance(step.get("uses"), str) and "actions/checkout" in step.get("uses", ""):
                    step.setdefault("with", {}).pop("ref", None)
    save_workflow(d, doc)


def m_workflow_yaml_unparseable(d):
    with open(os.path.join(d, "workflow.yml"), "w") as f:
        f.write("name: [broken\n  : ::\n")


def m_workflow_inputs_block_missing(d):
    doc = load_workflow(d)
    for key in (True, "on", "On", "ON"):
        if key in doc:
            del doc[key]
            break
    save_workflow(d, doc)


def m_workflow_jobs_block_missing(d):
    doc = load_workflow(d)
    doc.pop("jobs", None)
    save_workflow(d, doc)


# === Mutation registry ===

MUTATIONS = {
    "quarantined_self_review_rejected": m_quarantined_self_review_rejected,
    "parent_review_missing": m_parent_review_missing,
    "parent_review_issue_comment_only": m_parent_review_issue_comment_only,
    "parent_review_wrong_head": m_parent_review_wrong_head,
    "parent_review_after_child": m_parent_review_after_child,
    "parent_review_commented_without_marker": m_parent_review_commented_without_marker,
    "parent_review_approved_with_bad_json": m_parent_review_approved_with_bad_json,
    "latest_rejected_overrides_old_green": m_latest_rejected_overrides_old_green,
    "selected_changes_requested": m_selected_changes_requested,
    "selected_dismissed": m_selected_dismissed,
    "controller_json_head_mismatch": m_controller_json_head_mismatch,
    "controller_nx_required_false": m_controller_nx_required_false,
    "controller_ready_true": m_controller_ready_true,
    "controller_merge_true": m_controller_merge_true,
    "controller_release_true": m_controller_release_true,
    "controller_review_complete_false": m_controller_review_complete_false,
    "controller_classification_not_green": m_controller_classification_not_green,
    "controller_marker_duplicated_in_body": m_controller_marker_duplicated_in_body,
    "controller_json_blocks_duplicated": m_controller_json_blocks_duplicated,
    "report_edited_after_review": m_report_edited_after_review,
    "bootstrap_policy_green_without_body_evidence": m_bootstrap_policy_green_without_body_evidence,
    "bootstrap_wrong_review_id": m_bootstrap_wrong_review_id,
    "bootstrap_wrong_commit": m_bootstrap_wrong_commit,
    "bootstrap_wrong_classification": m_bootstrap_wrong_classification,
    "bootstrap_wrong_child": m_bootstrap_wrong_child,
    "bootstrap_reused_after_r7": m_bootstrap_reused_after_r7,
    "repair_wrong_review_id": m_repair_wrong_review_id,
    "repair_wrong_parent": m_repair_wrong_parent,
    "repair_wrong_classification": m_repair_wrong_classification,
    "repair_wrong_commit_message": m_repair_wrong_commit_message,
    "repair_wrong_workstream_trailer": m_repair_wrong_workstream_trailer,
    "repair_wrong_decision": m_repair_wrong_decision,
    "repair_wrong_review_state": m_repair_wrong_review_state,
    "repair_malformed_json": m_repair_malformed_json,
    "repair_marker_duplicated": m_repair_marker_duplicated,
    "repair_json_head_mismatch": m_repair_json_head_mismatch,
    "repair_review_incomplete": m_repair_review_incomplete,
    "repair_nx_required_false": m_repair_nx_required_false,
    "repair_unsafe_authorization": m_repair_unsafe_authorization,
    "repair_review_after_child": m_repair_review_after_child,
    "repair_forbidden_path": m_repair_forbidden_path,
    "repair_production_source_changed": m_repair_production_source_changed,
    "repair_merge_commit": m_repair_merge_commit,
    "repair_reused_after_fix1": m_repair_reused_after_fix1,
    "repair_quarantined_review_used": m_repair_quarantined_review_used,
    "repair_scope_missing": m_repair_scope_missing,
    "repair_scope_wrong_type_exact": m_repair_scope_wrong_type_exact,
    "repair_scope_wrong_type_prefix": m_repair_scope_wrong_type_prefix,
    "repair_scope_empty_entry": m_repair_scope_empty_entry,
    "repair_scope_duplicate": m_repair_scope_duplicate,
    "repair_scope_absolute": m_repair_scope_absolute,
    "repair_scope_traversal": m_repair_scope_traversal,
    "repair_scope_prefix_no_slash": m_repair_scope_prefix_no_slash,
    "repair_scope_outside_envelope": m_repair_scope_outside_envelope,
    "repair_scope_sources_declared": m_repair_scope_sources_declared,
    "repair_scope_tests_declared": m_repair_scope_tests_declared,
    "repair_scope_front_file_omitted": m_repair_scope_front_file_omitted,
    "repair_scope_gate1_changes_truth_py": m_repair_scope_gate1_changes_truth_py,
    "repair_scope_gate1_changes_truth_fixtures": m_repair_scope_gate1_changes_truth_fixtures,
    "repair_scope_old_r8_review_id": m_repair_scope_old_r8_review_id,
    "repair_scope_r9_rejects_gate_path": m_repair_scope_r9_rejects_gate_path,
    "repair_scope_tier_a_doc_denied": m_repair_scope_tier_a_doc_denied,
    "report_missing": m_report_missing,
    "report_malformed_current_head": m_report_malformed_current_head,
    "report_marker_duplicated": m_report_marker_duplicated,
    "report_json_block_duplicated": m_report_json_block_duplicated,
    "report_inline": m_report_inline,
    "report_reply": m_report_reply,
    "duplicate_current_head_reports": m_duplicate_current_head_reports,
    "historical_reports_do_not_conflict": m_historical_reports_do_not_conflict,
    "report_head_mismatch": m_report_head_mismatch,
    "report_parent_mismatch": m_report_parent_mismatch,
    "report_commit_count_invalid": m_report_commit_count_invalid,
    "report_workstream_mismatch": m_report_workstream_mismatch,
    "head_commit_message_missing": m_head_commit_message_missing,
    "head_workstream_trailer_missing": m_head_workstream_trailer_missing,
    "head_workstream_trailer_duplicated": m_head_workstream_trailer_duplicated,
    "head_workstream_trailer_invalid": m_head_workstream_trailer_invalid,
    "replay_malformed_marker_at_or_after_head": m_replay_malformed_marker_at_or_after_head,
    "replay_malformed_json_at_or_after_head": m_replay_malformed_json_at_or_after_head,
    "replay_historical_marker_missing_timestamp": m_replay_historical_marker_missing_timestamp,
    "replay_historical_marker_malformed_timestamp": m_replay_historical_marker_malformed_timestamp,
    "replay_duplicate_valid_current_head_reports": m_replay_duplicate_valid_current_head_reports,
    "replay_selected_exact_report_malformed": m_replay_selected_exact_report_malformed,
    "report_stop_false": m_report_stop_false,
    "report_next_workstream_true": m_report_next_workstream_true,
    "report_ready_true": m_report_ready_true,
    "report_merge_true": m_report_merge_true,
    "report_release_true": m_report_release_true,
    "report_before_commit": m_report_before_commit,
    "report_bool_used_as_integer": m_report_bool_used_as_integer,
    "report_duplicate_ci_jobs": m_report_duplicate_ci_jobs,
    "report_invalid_array_item": m_report_invalid_array_item,
    "report_extra_property": m_report_extra_property,
    "ci_run_missing": m_ci_run_missing,
    "ci_run_wrong_head": m_ci_run_wrong_head,
    "ci_run_wrong_workflow": m_ci_run_wrong_workflow,
    "ci_run_incomplete": m_ci_run_incomplete,
    "ci_run_failed": m_ci_run_failed,
    "ci_job_missing": m_ci_job_missing,
    "ci_job_failed": m_ci_job_failed,
    "ci_job_duplicate": m_ci_job_duplicate,
    "repository_mismatch": m_repository_mismatch,
    "pr_number_mismatch": m_pr_number_mismatch,
    "head_branch_mismatch": m_head_branch_mismatch,
    "base_branch_mismatch": m_base_branch_mismatch,
    "pr_closed": m_pr_closed,
    "pr_not_draft": m_pr_not_draft,
    "pr_merged": m_pr_merged,
    "pr_not_mergeable": m_pr_not_mergeable,
    "expected_head_invalid": m_expected_head_invalid,
    "merge_commit_rejected": m_merge_commit_rejected,
    "policy_missing": m_policy_missing,
    "policy_malformed": m_policy_malformed,
    "api_404_pr": m_api_404_pr,
    "api_404_commit": m_api_404_commit,
    "api_404_comments": m_api_404_comments,
    "api_404_reviews": m_api_404_reviews,
    "api_404_runs": m_api_404_runs,
    "api_404_jobs": m_api_404_jobs,
    "pagination_parse_failure": m_pagination_parse_failure,
    "pagination_page_type_invalid": m_pagination_page_type_invalid,
    "pagination_duplicate_id": m_pagination_duplicate_id,
    "fixture_json_malformed": m_fixture_json_malformed,
    "fixture_missing_pr": m_fixture_missing_pr,
    "fixture_missing_commit": m_fixture_missing_commit,
    "fixture_missing_reviews": m_fixture_missing_reviews,
    "fixture_missing_comments": m_fixture_missing_comments,
    "fixture_missing_runs": m_fixture_missing_runs,
    "fixture_missing_jobs": m_fixture_missing_jobs,
    "report_gate_submission_run_id_numeric": m_report_submission_run_numeric,
    "report_gate_submission_run_id_string": m_report_submission_run_string,
    "report_gate_submission_run_id_missing": m_report_submission_run_missing,


# === FIX2: Submission run receipt mutations ===
    "api_404_submission_runs": m_api_404_submission_runs,
    "api_404_submission_jobs": m_api_404_submission_jobs,
    "submission_run_wrong_head": m_submission_run_wrong_head,
    "submission_run_wrong_branch": m_submission_run_wrong_branch,
    "submission_run_wrong_event": m_submission_run_wrong_event,
    "submission_run_wrong_phase_in_name": m_submission_run_wrong_phase_in_name,
    "submission_run_wrong_pr_in_name": m_submission_run_wrong_pr_in_name,
    "submission_run_wrong_report_id_in_name": m_submission_run_wrong_report_id_in_name,
    "submission_run_wrong_head_in_name": m_submission_run_wrong_head_in_name,
    "submission_run_attempt_gt_one": m_submission_run_attempt_gt_one,
    "submission_run_incomplete": m_submission_run_incomplete,
    "submission_run_failed": m_submission_run_failed,
    "submission_gate_job_missing": m_submission_gate_job_missing,
    "submission_gate_job_failed": m_submission_gate_job_failed,
    "submission_gate_job_skipped": m_submission_gate_job_skipped,
    "submission_gate_job_cancelled": m_submission_gate_job_cancelled,
    "submission_gate_job_duplicate": m_submission_gate_job_duplicate,
    "report_created_after_submission_run": m_report_created_after_submission_run,
    "submission_completed_after_review": m_submission_completed_after_review,
    "submission_run_wrong_id": m_submission_run_wrong_id,
    "report_submission_run_numeric": m_report_submission_run_numeric,
    "report_submission_run_string": m_report_submission_run_string,
    "report_submission_run_missing": m_report_submission_run_missing,
    "controller_worker_report_comment_id_missing": m_controller_worker_report_comment_id_missing,
    "controller_submission_run_id_missing": m_controller_submission_run_id_missing,
    "controller_worker_report_comment_id_zero": m_controller_worker_report_comment_id_zero,
    "controller_submission_run_id_zero": m_controller_submission_run_id_zero,
    "controller_worker_report_comment_id_string": m_controller_worker_report_comment_id_string,
    "controller_submission_run_id_string": m_controller_submission_run_id_string,
    "controller_receipt_wrong_comment_id": m_controller_receipt_wrong_comment_id,
    "controller_receipt_wrong_submission_run_id": m_controller_receipt_wrong_submission_run_id,
    "report_submission_run_id_non_null": m_report_gate_submission_run_id_non_null,
    "submission_run_id_mismatch": m_submission_run_id_mismatch,
    "submission_runs_json_malformed": m_submission_runs_json_malformed,
    "submission_jobs_json_malformed": m_submission_jobs_json_malformed,
    "submission_runs_page_type_invalid": m_submission_runs_page_type_invalid,
    "submission_runs_duplicate_id": m_submission_runs_duplicate_id,
    "submission_job_id_non_integer": m_submission_job_id_non_integer,
    "fixture_missing_submission_runs": m_fixture_missing_submission_runs,
    "fixture_missing_submission_jobs": m_fixture_missing_submission_jobs,
    "fixture_missing_submission_comment": m_fixture_missing_submission_comment,
    "timestamp_malformed": m_timestamp_malformed,
    "commit_parent_missing": m_commit_parent_missing,
    "mergeable_unknown_after_retry": m_mergeable_unknown,
    "merge_commit_rejected": m_merge_commit_rejected,
    "repository_mismatch": m_repository_mismatch,
    "pr_number_mismatch": m_pr_number_mismatch,
    "head_branch_mismatch": m_head_branch_mismatch,
    "base_branch_mismatch": m_base_branch_mismatch,
    "pr_closed": m_pr_closed,
    "pr_not_draft": m_pr_not_draft,
    "pr_merged": m_pr_merged,
    "pr_not_mergeable": m_pr_not_mergeable,
    "expected_head_invalid": m_expected_head_invalid,
    "api_404_pr": m_api_404_pr,
    "api_404_commit": m_api_404_commit,
    "api_404_comments": m_api_404_comments,
    "api_404_reviews": m_api_404_reviews,


# === FIX3: Hosted submission lane mutations ===
    "receipt_display_title_wrong_phase": m_submission_run_wrong_phase_in_name,
    "receipt_display_title_wrong_pr": m_submission_run_wrong_pr_in_name,
    "receipt_display_title_wrong_head": m_submission_run_wrong_head_in_name,
    "receipt_display_title_wrong_report": m_submission_run_wrong_report_id_in_name,
    "receipt_submission_job_wrong_name": m_receipt_submission_job_wrong_name,
    "receipt_submission_job_missing": m_submission_gate_job_missing,
    "receipt_submission_job_duplicate": m_submission_gate_job_duplicate,
    "receipt_wrong_workflow_path": m_receipt_wrong_workflow_path,
    "workflow_worker_report_input_missing": m_workflow_worker_report_input_missing,
    "workflow_worker_report_input_optional": m_workflow_worker_report_input_optional,
    "workflow_submission_cli_arg_missing": m_workflow_submission_cli_arg_missing,
    "workflow_submission_cli_arg_hardcoded": m_workflow_submission_cli_arg_hardcoded,
    "workflow_review_cli_arg_missing": m_workflow_review_cli_arg_missing,
    "workflow_run_name_missing": m_workflow_run_name_missing,
    "workflow_run_name_missing_phase": m_workflow_run_name_missing_phase,
    "workflow_run_name_missing_pr": m_workflow_run_name_missing_pr,
    "workflow_run_name_missing_head": m_workflow_run_name_missing_head,
    "workflow_run_name_missing_report": m_workflow_run_name_missing_report,
    "workflow_submission_job_wrong_name": m_workflow_submission_job_wrong_name,
    "workflow_submission_job_duplicate": m_workflow_submission_job_duplicate,
    "workflow_generic_manual_job_restored": m_workflow_generic_manual_job_restored,
    "workflow_submission_condition_too_broad": m_workflow_submission_condition_too_broad,
    "workflow_checkout_expected_head_missing": m_workflow_checkout_expected_head_missing,
    "workflow_yaml_unparseable": m_workflow_yaml_unparseable,
    "workflow_inputs_block_missing": m_workflow_inputs_block_missing,
    "workflow_jobs_block_missing": m_workflow_jobs_block_missing,
}


def main():
    if len(sys.argv) != 3:
        print("Usage: apply-mutation.py <MUTATION_NAME> <temp_dir>", file=sys.stderr)
        sys.exit(2)

    mut_name = sys.argv[1]
    temp_dir = sys.argv[2]

    if mut_name not in MUTATIONS:
        print(f"Unknown mutation: {mut_name}", file=sys.stderr)
        sys.exit(2)

    func = MUTATIONS[mut_name]
    func(temp_dir)
    print(f"Applied {mut_name}")


if __name__ == "__main__":
    main()
