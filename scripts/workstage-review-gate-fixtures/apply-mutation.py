#!/usr/bin/env python3
"""
Mutation applier for workstage-review-gate fixture testing — U1R18-R7-FIX1.

Usage:
  python3 apply-mutation.py <MUTATION_NAME> <temp_dir>

Each mutation modifies fixture JSON files in the temp directory to simulate
a specific policy/protocol violation. If the mutation requires a modified
policy, a policy.json is written to the temp dir.

Mutation categories:
  parent/     — parent review and controller review validation
  bootstrap/  — bootstrap exception validation
  repair/     — repair authorization validation
  report/     — worker report validation
  ci/         — CI run and job validation
  pr/         — PR state and policy binding
  infra/      — infrastructure failures (missing/malformed files)
"""

import json
import os
import re
import sys

# === SHA constants (must match generate-green.py) ===
BOOTSTRAP_HEAD = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"
R7_HEAD = "f3ae89d2caa07930ffda7a84059ecdfb18942e3d"
FIX1_HEAD = "fe1234567890abcdef1234567890abcdef123456"
NORMAL_PARENT = "6656ec33d15289ce122f4ba9d1e2db71f260d8b7"
NORMAL_HEAD = "0123456789abcdef0123456789abcdef01234567"
HISTORICAL_HEAD = "9999999999999999999999999999999999999999"
WRONG_SHA = "cafe1234cafe1234cafe1234cafe1234cafe1234"

# === Timestamps ===
HEAD_COMMIT_TS = "2026-08-03T03:00:00Z"
WORKER_REPORT_TS = "2026-08-03T03:10:00Z"
HEAD_REVIEW_TS = "2026-08-03T03:15:00Z"
LATEST_ACCEPT_TS = "2026-08-03T03:20:00Z"
BEFORE_COMMIT_TS = "2026-08-03T02:00:00Z"

# === IDs ===
BOOTSTRAP_REVIEW_ID = 4840817794
REPAIR_REVIEW_ID = 4841397951
QUARANTINED_REVIEW_ID = 4841357081
NORMAL_REVIEW_ID = 4840817795

CI_RUN_ID = 30790400001
GATE_ADVANCE_RUN_ID = 30790400002

REQUIRED_JOBS = ["Swift Build", "Public Audit", "Recipe Validation", "License Validation", "Gitignore Validation"]
FIX1_WORKSTREAM = "U1R18-R7-FIX1"
REPAIR_COMMIT_MSG = "ci: close workstream review authority gate (U1R18-R7-FIX1)"
REPAIR_CLASSIFICATION = "RED_U1R18_R7_SELF_REVIEW_AND_SEQUENTIAL_GATE_FAIL_OPEN"
BOOTSTRAP_CLASSIFICATION = "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"

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


def save_policy(temp_dir, policy):
    save_json(temp_dir, "policy.json", policy)


def get_controller_review_body(commit_id, classification="GREEN_U1R18_R6_CONTROLLER_REVIEW_ACCEPTED",
                                decision="accepted", review_id=NORMAL_REVIEW_ID,
                                nx_required=True, ready=False, merge=False, release=False,
                                review_complete=True):
    json_body = {
        "schema_version": 1,
        "kind": "controller_review",
        "head_sha": commit_id,
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
        "workstream": FIX1_WORKSTREAM,
        "head_sha": head_sha,
        "parent_sha": parent_sha,
        "commit_count": 1,
        "core_ci_run_id": CI_RUN_ID,
        "core_ci_jobs": REQUIRED_JOBS,
        "gate_advance_run_id": GATE_ADVANCE_RUN_ID,
        "gate_submission_run_id": 0,
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
    commit["commit"]["message"] = REPAIR_COMMIT_MSG.replace("\n\nWorkstream: U1R18-R7-FIX1", "")
    save_json(d, "commit_HEAD.json", commit)


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
    for c in comments:
        if WORKER_MARKER in (c.get("body", "")):
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
    jobs.append({"name": "Swift Build", "conclusion": "success", "status": "completed"})
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
    "repair_forbidden_path": m_repair_forbidden_path,
    "repair_production_source_changed": m_repair_production_source_changed,
    "repair_merge_commit": m_repair_merge_commit,
    "repair_reused_after_fix1": m_repair_reused_after_fix1,
    "repair_quarantined_review_used": m_repair_quarantined_review_used,
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
    "fixture_missing": m_fixture_missing_reviews,
    "fixture_json_malformed": m_fixture_json_malformed,
    "pagination_parse_failure": m_pagination_parse_failure,
    "pagination_page_type_invalid": m_pagination_page_type_invalid,
    "pagination_duplicate_id": m_pagination_duplicate_id,
    "timestamp_malformed": m_timestamp_malformed,
    "commit_parent_missing": m_commit_parent_missing,
    "mergeable_unknown_after_retry": m_mergeable_unknown,
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
