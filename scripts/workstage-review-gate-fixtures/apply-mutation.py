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
REPAIR_REVIEW_ID = 4873335284
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
REPAIR_CLASSIFICATION = "RED_U1R18_R10_FIX1_SCOPE1_FIX5_TECHNICAL_GREEN_HISTORICAL_EVIDENCE_DELETION"
BOOTSTRAP_CLASSIFICATION = "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"

WORKER_REPORT_COMMENT_ID = 5161887211

CONTROLLER_MARKER = "<!-- macsteam-controller-review:v1 -->"
WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"
SOURCE_BRIDGE_MARKER = "<!-- macsteam-red-parent-source-fix-authorization:v1 -->"
GATE_FIX_MARKER = "<!-- macsteam-gate-fix-authorization:v1 -->"

# === Red parent source fix bridge constants (GATE1) ===
BRIDGE_PARENT = "a2d26b2e7ccd17c5c5ea153bf346572fa886a4be"   # source fix (parent of bridge)
BRIDGE_REJECTED_PARENT = "007e1d4e38d8e8a07950d5eff74c0453cf7a7dc6"
BRIDGE_HEAD = "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5"
BRIDGE_COMMENT_ID = 5211174534
BRIDGE_SUBJECT = "ci: admit rejected-parent source fix bridge (U1R18-R11-FIX1-GATE1)"
BRIDGE_WORKSTREAM = "U1R18-R11-FIX1-GATE1"
BRIDGE_SOURCE_SUBJECT = "fix: close local runtime acceptance completion path (U1R18-R11-FIX1)"
BRIDGE_SOURCE_WORKSTREAM = "U1R18-R11-FIX1"
BRIDGE_SOURCE_CI_RUN = 31136834727
BRIDGE_FAILED_RUN = 31136834743
BRIDGE_REJECTED_REVIEW_ID = 4878732820

# === GATE-FIX authorization constants (GATE1-FIX1) ===
GATE_FIX_PARENT = "db2dc127b37b4a93d0c157458e8bb0ecb01b45ac"
GATE_FIX_HEAD = "11aa22bb33cc44dd55ee66ff7788990011aabb22"
GATE_FIX_COMMENT_ID = 5211679289
GATE_FIX_SUBJECT = "ci: bind rejected review and failed advance evidence (U1R18-R11-FIX1-GATE1-FIX1)"
GATE_FIX_WORKSTREAM = "U1R18-R11-FIX1-GATE1-FIX1"
GATE_FIX_PARENT_ADVANCE_RUN = 31141723135
GATE_FIX_PARENT_CI_RUN = 31141723115

# === Red parent source fix CHAIN bridge constants (R12-FIX3-GATE1) ===
CHAIN_MARKER = "<!-- macsteam-red-parent-source-fix-chain-authorization:v1 -->"
CHAIN_COMMENT_ID = 5216469207
CHAIN_REJECTED_PARENT = "917b7e637629ed98bf6fa22ce38fafbf2793bb90"
CHAIN_FIX1 = "f2455860634b47c4360e26669981ddb6693ef392"
CHAIN_FIX2 = "e4d65437aa202e9c3b2b77b40c35d8cb5793a8e4"
CHAIN_FIX3 = "615455c88a4ddae1aa71739f228f609653ef61f4"
CHAIN_BRIDGE_SUBJECT = "ci: admit R12 durable receipt repair chain (U1R18-R12-FIX3-GATE1)"
CHAIN_BRIDGE_WORKSTREAM = "U1R18-R12-FIX3-GATE1"
CHAIN_CI_FIX1 = 31167252858
CHAIN_CI_FIX2 = 31170284028
CHAIN_CI_FIX3 = 31172730810
CHAIN_FAIL_FIX1 = 31167252882
CHAIN_FAIL_FIX2 = 31170283805
CHAIN_FAIL_FIX3 = 31172730722
CHAIN_REJECTED_REVIEW_ID = 4881429281
CHAIN_FIX1_WS = "U1R18-R12-FIX1"
CHAIN_FIX2_WS = "U1R18-R12-FIX2"
CHAIN_FIX3_WS = "U1R18-R12-FIX3"

# === Protocol recovery authorization constants (GATE1-RECOVERY1) ===
RECOVERY_PARENT = "c4940c37956efb0ae92740e9ef1bcb91c6d3d92f"
RECOVERY_HEAD = "aa11bb22cc33dd44ee55ff6677880099aa99ee11"
RECOVERY_SUBJECT = "ci: quarantine unauthorized GATE1 closure (U1R18-R12-FIX3-GATE1-RECOVERY1)"
RECOVERY_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1"
RECOVERY_CORRECTIVE_REVIEW_ID = 4888344128
RECOVERY_UNAUTHORIZED_REVIEW_ID = 4888334695
RECOVERY_REVIEW_RUN_ID = 31244379661
RECOVERY_REVIEW_JOB_ID = 900000301
RECOVERY_CORRECTIVE_CLASS = "RED_U1R18_R12_FIX3_GATE1_PROTOCOL_INTEGRITY_BREACH"

# === Protocol recovery FIX authorization constants (RECOVERY1-FIX1) ===
FIX_MARKER = "<!-- macsteam-protocol-recovery-fix-authorization:v1 -->"
FIX_PARENT_SHA = "464c18481aa19ea26b2ad574cea29632e208ce46"
FIX_HEAD_SHA = "180c5ea1ee2f4b3c9d8a7b6c5e4f3a2b1c0d9e8f"
FIX_COMMENT_ID = 5225253678
FIX_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1-FIX1"
FIX_SUBJECT = "ci: parse timestamped Review Gate proof (U1R18-R12-FIX3-GATE1-RECOVERY1-FIX1)"
FIX_PARENT_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1"
FIX_PARENT_SUBJECT = "ci: quarantine unauthorized GATE1 closure (U1R18-R12-FIX3-GATE1-RECOVERY1)"
FIX_FAILED_ADVANCE_RUN = 31247320739
FIX_FAILED_ADVANCE_JOB = 93077948452
FIX_FAILED_ADVANCE_GUARD = "protocol_recovery_review_run_final_state_wrong"
FIX_FAILED_ADVANCE_MSG = "Review Gate log final state != REVIEW_COMPLETE_NX_REQUIRED"
FIX_HISTORICAL_RUN = 31244379661
FIX_HISTORICAL_JOB = 93070440269
FIX_HISTORICAL_EXPECTED_STATE = "REVIEW_COMPLETE_NX_REQUIRED"
FIX_HISTORICAL_HEAD = "c4940c37956efb0ae92740e9ef1bcb91c6d3d92f"
FIX_CORRECTIVE_REVIEW = 4888344128

# === Protocol recovery FIX2 authorization constants (RECOVERY1-FIX2) ===
FIX2_MARKER = "<!-- macsteam-protocol-recovery-fix2-authorization:v1 -->"
FIX2_PARENT_SHA = "c4fc9093e01df80fdd8ca600d7391baad58b0081"
FIX2_HEAD_SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4"
FIX2_COMMENT_ID = 5225497249
FIX2_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1-FIX2"
FIX2_SUBJECT = "ci: select bounded final Review Gate state (U1R18-R12-FIX3-GATE1-RECOVERY1-FIX2)"
FIX2_PARENT_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1-FIX1"
FIX2_PARENT_SUBJECT = "ci: parse timestamped Review Gate proof (U1R18-R12-FIX3-GATE1-RECOVERY1-FIX1)"
FIX2_PARENT_ADVANCE_RUN = 31250113941
FIX2_PARENT_ADVANCE_JOB = 93085031472
FIX2_PARENT_ADVANCE_STATE = "CURRENT_WORKSTREAM_ACTIVE"
FIX2_PARENT_ADVANCE_AUTHORITY = "protocol_recovery_fix_authorization"
FIX2_PARENT_CORE_CI_RUN = 31250113951
FIX2_PARENT_CORE_CI_JOBS = 5

# === Protocol recovery FIX3 authorization constants (RECOVERY1-FIX3) ===
RECOVERY_FIX3_MARKER = "<!-- macsteam-protocol-recovery-fix3-authorization:v1 -->"
RECOVERY_FIX3_PARENT_SHA = "4eeb31ca84f1fda9f50611e6a1486d00eaafe0dd"
RECOVERY_FIX3_GRANDPARENT_SHA = "c4fc9093e01df80fdd8ca600d7391baad58b0081"
RECOVERY_FIX3_HEAD_SHA = "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5"
RECOVERY_FIX3_COMMENT_ID = 5226011784
RECOVERY_FIX3_REPORT_ID = 5225996101
RECOVERY_FIX3_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1-FIX3"
RECOVERY_FIX3_SUBJECT = "ci: bound Review Gate log before line materialization (U1R18-R12-FIX3-GATE1-RECOVERY1-FIX3)"
RECOVERY_FIX3_PARENT_WORKSTREAM = "U1R18-R12-FIX3-GATE1-RECOVERY1-FIX2"
RECOVERY_FIX3_PARENT_SUBJECT = "ci: select bounded final Review Gate state (U1R18-R12-FIX3-GATE1-RECOVERY1-FIX2)"
RECOVERY_FIX3_PARENT_ADVANCE_RUN = 31255264930
RECOVERY_FIX3_PARENT_ADVANCE_JOB = 93097599438
RECOVERY_FIX3_PARENT_ADVANCE_STATE = "CURRENT_WORKSTREAM_ACTIVE"
RECOVERY_FIX3_PARENT_ADVANCE_AUTHORITY = "protocol_recovery_fix2_authorization"
RECOVERY_FIX3_PARENT_CORE_CI_RUN = 31255262627
RECOVERY_FIX3_PARENT_CORE_CI_JOBS = 5

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


# === Red parent source fix bridge mutations (GATE1) ===
#
# Each bridges a source fix (BRIDGE_PARENT) rejected on BRIDGE_REJECTED_PARENT
# to a single bridge child (BRIDGE_HEAD) via the authorization comment.

def _bridge_files(d):
    path = os.path.join(d, "files.json")
    files = load_json(d, "files.json") if os.path.exists(path) else []
    files = files if isinstance(files, list) else files.get("files", [])
    return [f if isinstance(f, str) else f.get("filename", "") for f in files]


def _bridge_source_files(d):
    path = os.path.join(d, "source-fix.json")
    files = load_json(d, "source-fix.json") if os.path.exists(path) else []
    files = files if isinstance(files, list) else files.get("files", [])
    return [f if isinstance(f, str) else f.get("filename", "") for f in files]


def _auth_comment(d):
    c = load_json(d, "comment.json")
    return c


def _load_bridge_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return load_policy()


def _save_bridge_policy(d, policy):
    with open(os.path.join(d, "policy.json"), "w") as f:
        json.dump(policy, f, indent=2)
        f.write("\n")


def m_red_source_auth_comment_missing(d):
    path = os.path.join(d, "comment.json")
    if os.path.exists(path):
        os.remove(path)
    save_json(d, "comments.json", [])


def m_red_source_auth_comment_edited(d):
    c = _auth_comment(d)
    c["updated_at"] = "2026-08-07T02:00:00Z"
    save_json(d, "comment.json", c)


def m_red_source_auth_marker_duplicated(d):
    c = _auth_comment(d)
    c["body"] = c.get("body", "") + SOURCE_BRIDGE_MARKER + "\n```json\n{}\n```\n"
    save_json(d, "comment.json", c)


def m_red_source_auth_json_duplicated(d):
    c = _auth_comment(d)
    import re
    body = c.get("body", "")
    lead, _, rest = body.partition(SOURCE_BRIDGE_MARKER)
    c["body"] = lead + SOURCE_BRIDGE_MARKER + "\n```json\n{}\n```\n" + rest
    save_json(d, "comment.json", c)


def m_red_source_auth_schema_mismatch(d):
    c = _auth_comment(d)
    import re
    body = c["body"]
    body = body.replace('"schema_version": 1', '"schema_version": 2')
    c["body"] = body
    save_json(d, "comment.json", c)


def m_red_source_auth_policy_mismatch(d):
    policy = _load_bridge_policy(d)
    policy["red_parent_source_fix_bridge"]["bridge_workstream"] = "U1R18-R11-GATE1-WRONG"
    _save_bridge_policy(d, policy)


def m_red_source_auth_unsafe_authorization(d):
    c = _auth_comment(d)
    c["body"] = c.get("body", "").replace('"ready_authorized": false', '"ready_authorized": true')
    save_json(d, "comment.json", c)


def m_red_source_fix_wrong_parent(d):
    commit = load_json(d, "commit_PARENT.json")
    commit["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_PARENT.json", commit)


def m_red_source_fix_wrong_subject(d):
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = "ci: wrong subject\n\nWorkstream: U1R18-R11-FIX1"
    save_json(d, "commit_PARENT.json", parent)


def m_red_source_fix_wrong_workstream(d):
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = BRIDGE_SOURCE_SUBJECT + "\n\nWorkstream: U1R18-R11-WRONG"
    save_json(d, "commit_PARENT.json", parent)


def m_red_source_fix_forbidden_path(d):
    files = _bridge_source_files(d)
    files.append("unknown/path/outside.swift")
    save_json(d, "source-fix.json", files)


def m_red_source_fix_no_changed_files(d):
    save_json(d, "source-fix.json", [])


def m_red_source_ci_wrong_sha(d):
    runs = load_json(d, "runs.json")
    for r in runs.get("workflow_runs", []):
        if r.get("id") == BRIDGE_SOURCE_CI_RUN:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_red_source_ci_failed(d):
    runs = load_json(d, "runs.json")
    for r in runs.get("workflow_runs", []):
        if r.get("id") == BRIDGE_SOURCE_CI_RUN:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_red_source_ci_required_job_missing(d):
    jobs = load_json(d, "jobs.json")
    jobs = jobs.get("jobs", [])
    stop = False
    kept = []
    for j in jobs:
        if j.get("name") == "License Validation" and not stop:
            stop = True
            continue
        kept.append(j)
    save_json(d, "jobs.json", {"total_count": len(kept), "jobs": kept})


def m_red_bridge_wrong_subject(d):
    head = load_json(d, "commit_HEAD.json")
    head["commit"]["message"] = "ci: wrong bridge subject\n\nWorkstream: U1R18-R11-FIX1-GATE1"
    save_json(d, "commit_HEAD.json", head)


def m_red_bridge_wrong_workstream(d):
    head = load_json(d, "commit_HEAD.json")
    head["commit"]["message"] = BRIDGE_SUBJECT + "\n\nWorkstream: U1R18-R11-WRONG-BRIDGE"
    save_json(d, "commit_HEAD.json", head)


def m_red_bridge_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/gate/path.txt")
    save_json(d, "files.json", files)


# === Rejected controller review binding (GATE1-FIX1 hardening) ===
# Base fixture: advance_red_parent_source_fix_bridge.

def _bridge_reviews(d):
    path = os.path.join(d, "reviews.json")
    if not os.path.exists(path):
        return []
    data = load_json(d, "reviews.json")
    return data if isinstance(data, list) else [data]


def _bridge_review_body(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            return r.get("body", "")
    return ""


def m_red_bridge_rejected_review_missing(d):
    save_json(d, "reviews.json", [])


def m_red_bridge_rejected_review_wrong_id(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["id"] = 1111111111
    save_json(d, "reviews.json", reviews)


def m_red_bridge_rejected_review_wrong_commit(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["commit_id"] = WRONG_SHA
            r["body"] = r["body"].replace('"head_sha": "007e1d4e38d8e8a07950d5eff74c0453cf7a7dc6"',
                                          '"head_sha": "' + WRONG_SHA + '"')
    save_json(d, "reviews.json", reviews)


def m_red_bridge_rejected_review_wrong_decision(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["state"] = "APPROVED"
    save_json(d, "reviews.json", reviews)


def m_red_bridge_rejected_review_wrong_classification(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["body"] = r["body"].replace(
                '"RED_U1R18_R11_ACCEPTANCE_PATH_UNREACHABLE_AND_RECEIPT_DESTROYED"',
                '"RED_SOME_OTHER_CLASSIFICATION"')
    save_json(d, "reviews.json", reviews)


def m_red_bridge_rejected_review_incomplete(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["body"] = r["body"].replace('"review_complete": true',
                                          '"review_complete": false')
    save_json(d, "reviews.json", reviews)


def m_red_bridge_rejected_review_nx_false(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["body"] = r["body"].replace(
                '"nx_required_for_next_workstream": true',
                '"nx_required_for_next_workstream": false')
    save_json(d, "reviews.json", reviews)


def _bridge_review_flag(d, flag):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["body"] = r["body"].replace('"%s": false' % flag, '"%s": true' % flag)
    save_json(d, "reviews.json", reviews)


def m_red_bridge_rejected_review_ready_true(d):
    _bridge_review_flag(d, "ready_authorized")


def m_red_bridge_rejected_review_merge_true(d):
    _bridge_review_flag(d, "merge_authorized")


def m_red_bridge_rejected_review_release_true(d):
    _bridge_review_flag(d, "release_authorized")


def m_red_bridge_rejected_review_after_source_fix(d):
    reviews = _bridge_reviews(d)
    for r in reviews:
        if r.get("id") == BRIDGE_REJECTED_REVIEW_ID:
            r["submitted_at"] = "2026-08-07T06:00:00Z"
    save_json(d, "reviews.json", reviews)


# === Failed Advance run binding (GATE1-FIX1 hardening) ===

def _bridge_runs(d):
    return load_json(d, "runs.json")


def _bridge_jobs(d):
    return load_json(d, "jobs.json")


def m_red_failed_advance_incomplete(d):
    runs = _bridge_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == BRIDGE_FAILED_RUN:
            r["status"] = "in_progress"
            r["conclusion"] = None
    save_json(d, "runs.json", runs)


def m_red_failed_advance_success(d):
    runs = _bridge_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == BRIDGE_FAILED_RUN:
            r["conclusion"] = "success"
    save_json(d, "runs.json", runs)


def m_red_failed_advance_job_missing(d):
    jobs = _bridge_jobs(d)
    jobs = jobs.get("jobs", [])
    jobs = [j for j in jobs if not (j.get("run_id") == BRIDGE_FAILED_RUN
                                    and j.get("name") == "Advance Gate")]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_red_failed_advance_job_success(d):
    jobs = _bridge_jobs(d)
    jobs = jobs.get("jobs", [])
    for j in jobs:
        if j.get("run_id") == BRIDGE_FAILED_RUN and j.get("name") == "Advance Gate":
            j["conclusion"] = "success"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def _bridge_job_logs(d):
    return load_json(d, "job-logs.json")


def m_red_failed_advance_guard_missing(d):
    logs = _bridge_job_logs(d)
    for k in logs:
        logs[k] = "::group::advance\nnothing here\n::endgroup::\n"
    save_json(d, "job-logs.json", logs)


def _replace_log_guard(d, old, new):
    logs = _bridge_job_logs(d)
    for k in logs:
        logs[k] = logs[k].replace(old, new)
    save_json(d, "job-logs.json", logs)


def m_red_failed_advance_guard_mismatch(d):
    _replace_log_guard(d, '"guard_label":"latest_rejected_overrides_old_green"',
                       '"guard_label":"some_other_guard"')


def m_red_failed_advance_wrong_head(d):
    _replace_log_guard(d, '"head_sha":"' + BRIDGE_PARENT + '"',
                       '"head_sha":"' + WRONG_SHA + '"')


def m_red_failed_advance_wrong_parent(d):
    _replace_log_guard(d, '"parent_sha":"' + BRIDGE_REJECTED_PARENT + '"',
                       '"parent_sha":"' + WRONG_SHA + '"')


def m_red_source_auth_after_bridge(d):
    c = _auth_comment(d)
    c["created_at"] = "2026-08-07T07:00:00Z"
    c["updated_at"] = "2026-08-07T07:00:00Z"
    save_json(d, "comment.json", c)


# === GATE-FIX authorization lane mutations (GATE1-FIX1) ===
# Base fixture: advance_gate_fix_authorization.

def _gate_fix_comment(d):
    return load_json(d, "comment.json")


def _gate_fix_head(d):
    return load_json(d, "commit_HEAD.json")


def _gate_fix_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    p = load_policy()
    return p


def _save_gate_fix_policy(d, p):
    save_json(d, "policy.json", p)


def m_gate_fix_auth_missing(d):
    path = os.path.join(d, "comment.json")
    if os.path.exists(path):
        os.remove(path)


def m_gate_fix_auth_edited(d):
    c = _gate_fix_comment(d)
    c["updated_at"] = "2026-08-07T03:10:00Z"
    save_json(d, "comment.json", c)


def m_gate_fix_auth_marker_duplicated(d):
    c = _gate_fix_comment(d)
    c["body"] = GATE_FIX_MARKER + "\n" + c["body"]
    save_json(d, "comment.json", c)


def m_gate_fix_auth_json_duplicated(d):
    c = _gate_fix_comment(d)
    lead, _, rest = c["body"].partition(GATE_FIX_MARKER)
    c["body"] = lead + GATE_FIX_MARKER + "\n```json\n{}\n```\n" + rest
    save_json(d, "comment.json", c)


def m_gate_fix_auth_policy_mismatch(d):
    p = _gate_fix_policy(d)
    p["gate_fix_authorization"]["required_workstream"] = "U1R18-R11-WRONG-FIX1"
    _save_gate_fix_policy(d, p)


def m_gate_fix_auth_after_child(d):
    c = _gate_fix_comment(d)
    c["created_at"] = "2026-08-07T09:00:00Z"
    c["updated_at"] = "2026-08-07T09:00:00Z"
    save_json(d, "comment.json", c)


def m_gate_fix_wrong_parent(d):
    head = _gate_fix_head(d)
    head["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)
    p = _gate_fix_policy(d)
    p["gate_fix_authorization"]["parent_sha"] = WRONG_SHA
    _save_gate_fix_policy(d, p)
    c = _gate_fix_comment(d)
    c["body"] = c["body"].replace(GATE_FIX_PARENT, WRONG_SHA)
    save_json(d, "comment.json", c)
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = "ci: not the bridge child\n\nWorkstream: U1R18-R11-UNRELATED"
    save_json(d, "commit_PARENT.json", parent)


def m_gate_fix_reused_by_grandchild(d):
    head = _gate_fix_head(d)
    head["parents"] = [{"sha": BRIDGE_PARENT}]
    save_json(d, "commit_HEAD.json", head)
    p = _gate_fix_policy(d)
    p.pop("red_parent_source_fix_bridge", None)
    _save_gate_fix_policy(d, p)


def m_gate_fix_wrong_subject(d):
    head = _gate_fix_head(d)
    head["commit"]["message"] = "ci: wrong subject\n\nWorkstream: %s" % GATE_FIX_WORKSTREAM
    save_json(d, "commit_HEAD.json", head)


def m_gate_fix_wrong_workstream(d):
    head = _gate_fix_head(d)
    head["commit"]["message"] = GATE_FIX_SUBJECT + "\n\nWorkstream: U1R18-R11-WRONG-FIX"
    save_json(d, "commit_HEAD.json", head)


def m_gate_fix_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/gate/extra.txt")
    save_json(d, "files.json", files)


def _gate_fix_flag(d, flag):
    c = _gate_fix_comment(d)
    c["body"] = c["body"].replace('"%s": false' % flag, '"%s": true' % flag)
    save_json(d, "comment.json", c)


def m_gate_fix_ready_true(d):
    _gate_fix_flag(d, "ready_authorized")


def m_gate_fix_merge_true(d):
    _gate_fix_flag(d, "merge_authorized")


def m_gate_fix_release_true(d):
    _gate_fix_flag(d, "release_authorized")


# === Red parent source fix CHAIN bridge mutations (R12-FIX3-GATE1) ===
# Base fixture: advance_red_parent_source_fix_chain_bridge.
#
# The chain authorization lives in a single top-level comment whose body carries
# the chain witness JSON.  Every node in the declared chain is individually
# proven (identity, scope, core CI, failed advance) and the bridge child (HEAD)
# must be the ONLY direct child of the terminal source fix.

def _chain_comment(d):
    return load_json(d, "comment.json")


def _chain_auth(d):
    return json.loads(re.search(r"```json\n(.*?)\n```", _chain_comment(d)["body"], re.S).group(1))


def _save_chain_auth(d, auth):
    c = _chain_comment(d)
    body = c["body"]
    new_block = "```json\n" + json.dumps(auth, indent=2) + "\n```"
    body = re.sub(r"```json\n.*?\n```", lambda mblk: new_block, body, count=1, flags=re.S)
    c["body"] = body
    save_json(d, "comment.json", c)


def _chain_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return load_policy()


def _save_chain_policy(d, p):
    save_json(d, "policy.json", p)


def _chain_commit(d, sha):
    return load_json(d, "commit_%s.json" % sha)


def m_red_chain_auth_comment_missing(d):
    path = os.path.join(d, "comment.json")
    if os.path.exists(path):
        os.remove(path)
    save_json(d, "comments.json", [])


def m_red_chain_auth_comment_edited(d):
    c = _chain_comment(d)
    c["updated_at"] = "2026-08-07T12:00:00Z"
    save_json(d, "comment.json", c)


def m_red_chain_auth_after_bridge(d):
    c = _chain_comment(d)
    c["created_at"] = "2026-08-07T13:00:00Z"
    c["updated_at"] = "2026-08-07T13:00:00Z"
    save_json(d, "comment.json", c)


def m_red_chain_auth_marker_duplicated(d):
    c = _chain_comment(d)
    c["body"] = CHAIN_MARKER + "\n" + c["body"]
    save_json(d, "comment.json", c)


def m_red_chain_auth_json_duplicated(d):
    c = _chain_comment(d)
    lead, _, rest = c["body"].partition(CHAIN_MARKER)
    c["body"] = lead + CHAIN_MARKER + "\n```json\n{}\n```\n" + rest
    save_json(d, "comment.json", c)


def m_red_chain_auth_schema_mismatch(d):
    auth = _chain_auth(d)
    auth["schema_version"] = 2
    _save_chain_auth(d, auth)


def m_red_chain_auth_policy_mismatch(d):
    p = _chain_policy(d)
    p["red_parent_source_fix_chain_bridge"]["bridge_workstream"] = "U1R18-R12-WRONG-GATE1"
    _save_chain_policy(d, p)


def m_red_chain_auth_unsafe_authorization(d):
    auth = _chain_auth(d)
    auth["ready_authorized"] = True
    _save_chain_auth(d, auth)


def m_red_chain_auth_single_child_required(d):
    auth = _chain_auth(d)
    auth["single_direct_child_only"] = False
    _save_chain_auth(d, auth)


def m_red_chain_auth_chain_length_mismatch(d):
    auth = _chain_auth(d)
    auth["source_fix_chain"] = auth["source_fix_chain"][:2]
    _save_chain_auth(d, auth)


def m_red_chain_wrong_root(d):
    auth = _chain_auth(d)
    auth["source_fix_chain"][0]["parent_sha"] = WRONG_SHA
    _save_chain_auth(d, auth)
    p = _chain_policy(d)
    p["red_parent_source_fix_chain_bridge"]["source_fix_chain"][0]["parent_sha"] = WRONG_SHA
    _save_chain_policy(d, p)


def m_red_chain_wrong_link(d):
    auth = _chain_auth(d)
    auth["source_fix_chain"][1]["parent_sha"] = WRONG_SHA
    _save_chain_auth(d, auth)
    p = _chain_policy(d)
    p["red_parent_source_fix_chain_bridge"]["source_fix_chain"][1]["parent_sha"] = WRONG_SHA
    _save_chain_policy(d, p)


def m_red_chain_wrong_terminal(d):
    auth = _chain_auth(d)
    auth["source_fix_chain"][2]["sha"] = WRONG_SHA
    _save_chain_auth(d, auth)
    p = _chain_policy(d)
    p["red_parent_source_fix_chain_bridge"]["source_fix_chain"][2]["sha"] = WRONG_SHA
    _save_chain_policy(d, p)


def m_red_chain_fix1_wrong_parent(d):
    commit = _chain_commit(d, CHAIN_FIX1)
    commit["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_%s.json" % CHAIN_FIX1, commit)


def m_red_chain_fix1_wrong_subject(d):
    commit = _chain_commit(d, CHAIN_FIX1)
    commit["commit"]["message"] = "fix: wrong subject\n\nWorkstream: U1R18-R12-FIX1"
    save_json(d, "commit_%s.json" % CHAIN_FIX1, commit)


def m_red_chain_fix1_wrong_workstream(d):
    commit = _chain_commit(d, CHAIN_FIX1)
    commit["commit"]["message"] = "fix: harden durable acceptance receipt I/O (U1R18-R12-FIX1)\n\nWorkstream: U1R18-R12-WRONG"
    save_json(d, "commit_%s.json" % CHAIN_FIX1, commit)


def m_red_chain_fix1_forbidden_path(d):
    files = load_json(d, "files_%s.json" % CHAIN_FIX1)
    files = files if isinstance(files, list) else files.get("files", [])
    files = [f if isinstance(f, str) else f.get("filename", "") for f in files]
    files.append("unknown/path/outside.swift")
    save_json(d, "files_%s.json" % CHAIN_FIX1, files)


def m_red_chain_fix1_no_changed_files(d):
    save_json(d, "files_%s.json" % CHAIN_FIX1, [])


def m_red_chain_ci_wrong_sha(d):
    runs = load_json(d, "runs.json")
    for r in runs.get("workflow_runs", []):
        if r.get("id") == CHAIN_CI_FIX1:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_red_chain_ci_failed(d):
    runs = load_json(d, "runs.json")
    for r in runs.get("workflow_runs", []):
        if r.get("id") == CHAIN_CI_FIX1:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_red_chain_ci_required_job_missing(d):
    jobs = load_json(d, "jobs.json")
    jobs = jobs.get("jobs", [])
    stop = False
    kept = []
    for j in jobs:
        if j.get("run_id") == CHAIN_CI_FIX1 and j.get("name") == "License Validation" and not stop:
            stop = True
            continue
        kept.append(j)
    save_json(d, "jobs.json", {"total_count": len(kept), "jobs": kept})


# --- chain node failed advance (targets the FIX1 node fail run) ---

def _chain_fail_run(d):
    return load_json(d, "runs.json")


def _chain_jobs(d):
    return load_json(d, "jobs.json")


def _chain_job_logs(d):
    return load_json(d, "job-logs.json")


def _chain_advance_job_id():
    return 900000006


def m_red_chain_advance_incomplete(d):
    runs = _chain_fail_run(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == CHAIN_FAIL_FIX1:
            r["status"] = "in_progress"
            r["conclusion"] = None
    save_json(d, "runs.json", runs)


def m_red_chain_advance_not_failed(d):
    runs = _chain_fail_run(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == CHAIN_FAIL_FIX1:
            r["conclusion"] = "success"
    save_json(d, "runs.json", runs)


def m_red_chain_advance_job_missing(d):
    jobs = _chain_jobs(d)
    jobs = jobs.get("jobs", [])
    jobs = [j for j in jobs if not (j.get("run_id") == CHAIN_FAIL_FIX1
                                    and j.get("name") == "Advance Gate")]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_red_chain_advance_job_not_failed(d):
    jobs = _chain_jobs(d)
    jobs = jobs.get("jobs", [])
    for j in jobs:
        if j.get("run_id") == CHAIN_FAIL_FIX1 and j.get("name") == "Advance Gate":
            j["conclusion"] = "success"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_red_chain_advance_guard_missing(d):
    logs = _chain_job_logs(d)
    for k in logs:
        logs[k] = "::group::advance\nnothing here\n::endgroup::\n"
    save_json(d, "job-logs.json", logs)


def _chain_replace_log_guard(d, old, new):
    logs = _chain_job_logs(d)
    for k in logs:
        logs[k] = logs[k].replace(old, new)
    save_json(d, "job-logs.json", logs)


def m_red_chain_advance_guard_mismatch(d):
    _chain_replace_log_guard(d, '"guard_label":"latest_rejected_overrides_old_green"',
                             '"guard_label":"some_other_guard"')


def m_red_chain_advance_wrong_head(d):
    _chain_replace_log_guard(d, '"head_sha":"' + CHAIN_FIX1 + '"',
                             '"head_sha":"' + WRONG_SHA + '"')


def m_red_chain_advance_wrong_parent(d):
    _chain_replace_log_guard(d, '"parent_sha":"' + CHAIN_REJECTED_PARENT + '"',
                             '"parent_sha":"' + WRONG_SHA + '"')


# --- chain bridge child (HEAD commit identity + scope) ---

def m_red_chain_bridge_no_changed_files(d):
    save_json(d, "files.json", [])


def m_red_chain_bridge_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/gate/path.txt")
    save_json(d, "files.json", files)


def m_red_chain_bridge_wrong_subject(d):
    head = load_json(d, "commit_HEAD.json")
    head["commit"]["message"] = "ci: wrong chain bridge subject\n\nWorkstream: %s" % CHAIN_BRIDGE_WORKSTREAM
    save_json(d, "commit_HEAD.json", head)


def m_red_chain_bridge_wrong_workstream(d):
    head = load_json(d, "commit_HEAD.json")
    head["commit"]["message"] = CHAIN_BRIDGE_SUBJECT + "\n\nWorkstream: U1R18-R12-WRONG-BRIDGE"
    save_json(d, "commit_HEAD.json", head)


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


# === Protocol recovery authorization lane mutations (GATE1-RECOVERY1) ===
# Base fixture: green/advance_protocol_recovery_authorization.
#
# The recovery lane has no PR comment — the policy object itself is the
# authority. Every mutation below either breaks one of the proven breach
# artifacts (corrective review, unauthorized review, unauthorized review run /
# its REVIEW_COMPLETE_NX_REQUIRED final state), removes a quarantine binding,
# or violates the single direct-child gate-only contract.

def _recovery_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return load_policy()


def _save_recovery_policy(d, p):
    save_json(d, "policy.json", p)


def _recovery_reviews(d):
    data = load_json(d, "reviews.json")
    return data if isinstance(data, list) else [data]


def _recovery_runs(d):
    return load_json(d, "runs.json")


def _recovery_jobs(d):
    return load_json(d, "jobs.json")


def _recovery_job_logs(d):
    return load_json(d, "job-logs.json")


def _recovery_review_subject(d):
    return load_json(d, "commit_HEAD.json")


def m_protocol_recovery_corrective_review_missing(d):
    reviews = _recovery_reviews(d)
    reviews = [r for r in reviews if r.get("id") != RECOVERY_CORRECTIVE_REVIEW_ID]
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_corrective_review_wrong_classification(d):
    reviews = _recovery_reviews(d)
    for r in reviews:
        if r.get("id") == RECOVERY_CORRECTIVE_REVIEW_ID:
            r["body"] = r["body"].replace(RECOVERY_CORRECTIVE_CLASS, "RED_U1R18_WRONG_CLASSIFICATION")
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_corrective_review_quarantined(d):
    p = _recovery_policy(d)
    q = p.get("quarantined_review_ids", [])
    if RECOVERY_CORRECTIVE_REVIEW_ID not in q:
        q.append(RECOVERY_CORRECTIVE_REVIEW_ID)
    _save_recovery_policy(d, p)


def m_protocol_recovery_unauthorized_review_missing(d):
    reviews = _recovery_reviews(d)
    reviews = [r for r in reviews if r.get("id") != RECOVERY_UNAUTHORIZED_REVIEW_ID]
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_unauthorized_review_not_quarantined(d):
    p = _recovery_policy(d)
    q = p.get("quarantined_review_ids", [])
    if RECOVERY_UNAUTHORIZED_REVIEW_ID in q:
        q.remove(RECOVERY_UNAUTHORIZED_REVIEW_ID)
    _save_recovery_policy(d, p)


def m_protocol_recovery_review_run_missing(d):
    runs = _recovery_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != RECOVERY_REVIEW_RUN_ID]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_review_run_not_success(d):
    runs = _recovery_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == RECOVERY_REVIEW_RUN_ID:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_protocol_recovery_review_run_wrong_head(d):
    runs = _recovery_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == RECOVERY_REVIEW_RUN_ID:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_protocol_recovery_review_run_not_quarantined(d):
    p = _recovery_policy(d)
    q = p.get("quarantined_review_run_ids", [])
    if RECOVERY_REVIEW_RUN_ID in q:
        q.remove(RECOVERY_REVIEW_RUN_ID)
    _save_recovery_policy(d, p)


def m_protocol_recovery_review_job_not_success(d):
    data = _recovery_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    for j in jobs:
        if j.get("run_id") == RECOVERY_REVIEW_RUN_ID and j.get("name") == "Review Gate":
            j["conclusion"] = "failure"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_review_run_final_state_wrong(d):
    logs = _recovery_job_logs(d)
    key = str(RECOVERY_REVIEW_JOB_ID)
    if key in logs:
        logs[key] = logs[key].replace("REVIEW_COMPLETE_NX_REQUIRED",
                                      "WAITING_FOR_CONTROLLER_REVIEW")
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_chronology_wrong(d):
    reviews = _recovery_reviews(d)
    for r in reviews:
        if r.get("id") == RECOVERY_CORRECTIVE_REVIEW_ID:
            r["submitted_at"] = "2026-08-08T06:30:00Z"
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_wrong_parent(d):
    head = _recovery_review_subject(d)
    head["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)
    p = _recovery_policy(d)
    p["protocol_recovery_authorization"]["parent_sha"] = WRONG_SHA
    _save_recovery_policy(d, p)
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = "ci: not the recovery parent\n\nWorkstream: U1R18-R12-UNRELATED"
    save_json(d, "commit_PARENT.json", parent)


def m_protocol_recovery_wrong_subject(d):
    head = _recovery_review_subject(d)
    head["commit"]["message"] = "ci: wrong recovery subject\n\nWorkstream: " + RECOVERY_WORKSTREAM
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_wrong_workstream(d):
    head = _recovery_review_subject(d)
    head["commit"]["message"] = RECOVERY_SUBJECT + "\n\nWorkstream: U1R18-R12-WRONG-RECOVERY"
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/recovery/outside.txt")
    save_json(d, "files.json", files)


def m_protocol_recovery_merge_commit(d):
    head = _recovery_review_subject(d)
    head["parents"] = [{"sha": RECOVERY_PARENT}, {"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)


def _recovery_flag(d, flag):
    reviews = _recovery_reviews(d)
    for r in reviews:
        if r.get("id") == RECOVERY_CORRECTIVE_REVIEW_ID:
            r["body"] = r["body"].replace('"%s": false' % flag, '"%s": true' % flag)
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_ready_true(d):
    _recovery_flag(d, "ready_authorized")


def m_protocol_recovery_merge_true(d):
    _recovery_flag(d, "merge_authorized")


def m_protocol_recovery_release_true(d):
    _recovery_flag(d, "release_authorized")


def m_protocol_recovery_second_child(d):
    p = _recovery_policy(d)
    p["protocol_recovery_authorization"]["single_direct_child_only"] = False
    _save_recovery_policy(d, p)


# === Protocol recovery FIX authorization lane mutations (RECOVERY1-FIX1) ===
# Base fixture: advance_protocol_recovery_fix_authorization.

def _fix_comment(d):
    return load_json(d, "comment.json")


def _fix_head(d):
    return load_json(d, "commit_HEAD.json")


def _fix_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return load_policy()


def _save_fix_policy(d, p):
    save_json(d, "policy.json", p)


def _fix_runs(d):
    return load_json(d, "runs.json")


def _fix_jobs(d):
    return load_json(d, "jobs.json")


def _fix_job_logs(d):
    return load_json(d, "job-logs.json")


def _fix_reviews(d):
    return load_json(d, "reviews.json")


def m_protocol_recovery_fix_auth_missing(d):
    path = os.path.join(d, "comment.json")
    if os.path.exists(path):
        os.remove(path)


def m_protocol_recovery_fix_auth_edited(d):
    c = _fix_comment(d)
    c["updated_at"] = "2026-08-08T08:10:00Z"
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix_auth_marker_duplicated(d):
    c = _fix_comment(d)
    c["body"] = FIX_MARKER + "\n" + c["body"]
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix_auth_json_duplicated(d):
    c = _fix_comment(d)
    lead, _, rest = c["body"].partition(FIX_MARKER)
    c["body"] = lead + FIX_MARKER + "\n```json\n{}\n```\n" + rest
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix_auth_policy_mismatch(d):
    p = _fix_policy(d)
    p["protocol_recovery_fix_authorization"]["required_workstream"] = "U1R18-R12-WRONG-FIX1"
    _save_fix_policy(d, p)


def m_protocol_recovery_fix_auth_after_child(d):
    c = _fix_comment(d)
    c["created_at"] = "2026-08-08T09:00:00Z"
    c["updated_at"] = "2026-08-08T09:00:00Z"
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix_auth_unsafe_authorization(d):
    c = _fix_comment(d)
    c["body"] = c["body"].replace('"ready_authorized": false', '"ready_authorized": true')
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix_wrong_parent(d):
    head = _fix_head(d)
    head["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)
    p = _fix_policy(d)
    p["protocol_recovery_fix_authorization"]["parent_sha"] = WRONG_SHA
    _save_fix_policy(d, p)
    c = _fix_comment(d)
    c["body"] = c["body"].replace(FIX_PARENT_SHA, WRONG_SHA)
    save_json(d, "comment.json", c)
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = "ci: not the recovery fix parent\n\nWorkstream: U1R18-R12-UNRELATED"
    save_json(d, "commit_PARENT.json", parent)


def m_protocol_recovery_fix_wrong_subject(d):
    head = _fix_head(d)
    head["commit"]["message"] = "ci: wrong subject\n\nWorkstream: %s" % FIX_WORKSTREAM
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix_wrong_workstream(d):
    head = _fix_head(d)
    head["commit"]["message"] = FIX_SUBJECT + "\n\nWorkstream: U1R18-R12-WRONG-FIX"
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/fix/extra.txt")
    save_json(d, "files.json", files)


def m_protocol_recovery_fix_second_child(d):
    p = _fix_policy(d)
    p["protocol_recovery_fix_authorization"]["single_direct_child_only"] = False
    _save_fix_policy(d, p)
    c = _fix_comment(d)
    c["body"] = c["body"].replace('"single_direct_child_only": true',
                                  '"single_direct_child_only": false')
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix_failed_advance_missing(d):
    runs = _fix_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != FIX_FAILED_ADVANCE_RUN]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix_failed_advance_not_failed(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX_FAILED_ADVANCE_RUN:
            r["conclusion"] = "success"
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix_failed_advance_job_missing(d):
    data = _fix_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    jobs = [j for j in jobs if j.get("id") != FIX_FAILED_ADVANCE_JOB]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix_failed_advance_job_not_failed(d):
    data = _fix_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    for j in jobs:
        if j.get("id") == FIX_FAILED_ADVANCE_JOB:
            j["conclusion"] = "success"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix_failed_advance_guard_missing(d):
    logs = _fix_job_logs(d)
    key = str(FIX_FAILED_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace('"guard_label":', '"no_guard":')
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_failed_advance_guard_mismatch(d):
    logs = _fix_job_logs(d)
    key = str(FIX_FAILED_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace(FIX_FAILED_ADVANCE_GUARD, "wrong_guard_label")
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_failed_advance_wrong_head(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX_FAILED_ADVANCE_RUN:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix_failed_advance_wrong_parent(d):
    logs = _fix_job_logs(d)
    key = str(FIX_FAILED_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace(FIX_HISTORICAL_HEAD, WRONG_SHA)
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_review_gate_run_missing(d):
    runs = _fix_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != FIX_HISTORICAL_RUN]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix_review_gate_run_not_success(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX_HISTORICAL_RUN:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix_review_gate_wrong_head(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX_HISTORICAL_RUN:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix_review_gate_job_missing(d):
    data = _fix_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    jobs = [j for j in jobs if j.get("id") != FIX_HISTORICAL_JOB]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix_review_gate_job_not_success(d):
    data = _fix_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    for j in jobs:
        if j.get("id") == FIX_HISTORICAL_JOB:
            j["conclusion"] = "failure"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix_review_gate_final_state_missing(d):
    logs = _fix_job_logs(d)
    key = str(FIX_HISTORICAL_JOB)
    if key in logs:
        out = []
        for line in logs[key].splitlines():
            payload = line
            m = re.search(r"^\S+\s+", line)
            if m:
                payload = line[m.end():]
            if payload.lstrip().startswith("{") and FIX_HISTORICAL_EXPECTED_STATE in payload:
                continue
            out.append(line)
        logs[key] = "\n".join(out)
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_review_gate_final_state_wrong(d):
    logs = _fix_job_logs(d)
    key = str(FIX_HISTORICAL_JOB)
    if key in logs:
        logs[key] = logs[key].replace(FIX_HISTORICAL_HEAD, WRONG_SHA)
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_review_gate_final_state_untimestamped(d):
    logs = _fix_job_logs(d)
    key = str(FIX_HISTORICAL_JOB)
    if key in logs:
        log = logs[key]
        logs[key] = re.sub(r"^2026-08-08T[0-9:.]+Z\s+", "", log, flags=re.MULTILINE)
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_review_gate_final_state_outside_window(d):
    logs = _fix_job_logs(d)
    key = str(FIX_HISTORICAL_JOB)
    if key in logs:
        logs[key] = logs[key].replace("2026-08-08T06:39:04.1690260Z",
                                      "2026-08-08T06:40:00.1690260Z")
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix_corrective_review_missing(d):
    reviews = _fix_reviews(d)
    reviews = [r for r in reviews if r.get("id") != FIX_CORRECTIVE_REVIEW]
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_fix_corrective_review_not_rejected(d):
    reviews = _fix_reviews(d)
    for r in reviews:
        if r.get("id") == FIX_CORRECTIVE_REVIEW:
            r["state"] = "APPROVED"
            r["body"] = r["body"].replace('"decision": "rejected"', '"decision": "accepted"')
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_fix_corrective_review_wrong_classification(d):
    reviews = _fix_reviews(d)
    for r in reviews:
        if r.get("id") == FIX_CORRECTIVE_REVIEW:
            r["body"] = r["body"].replace(RECOVERY_CORRECTIVE_CLASS, "RED_U1R18_WRONG_CLASSIFICATION")
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_fix_corrective_review_quarantined(d):
    p = _fix_policy(d)
    q = p.get("quarantined_review_ids", [])
    if FIX_CORRECTIVE_REVIEW not in q:
        q.append(FIX_CORRECTIVE_REVIEW)
    _save_fix_policy(d, p)


def m_protocol_recovery_fix_corrective_review_incomplete(d):
    reviews = _fix_reviews(d)
    for r in reviews:
        if r.get("id") == FIX_CORRECTIVE_REVIEW:
            r["body"] = r["body"].replace('"review_complete": true', '"review_complete": false')
    save_json(d, "reviews.json", reviews)


def _fix_review_flag(d, flag):
    reviews = _fix_reviews(d)
    for r in reviews:
        if r.get("id") == FIX_CORRECTIVE_REVIEW:
            r["body"] = r["body"].replace('"%s": false' % flag, '"%s": true' % flag)
    save_json(d, "reviews.json", reviews)


def m_protocol_recovery_fix_unsafe_authorization(d):
    _fix_review_flag(d, "release_authorized")


def m_protocol_recovery_fix_chronology_wrong(d):
    reviews = _fix_reviews(d)
    for r in reviews:
        if r.get("id") == FIX_CORRECTIVE_REVIEW:
            r["submitted_at"] = "2026-08-08T06:38:00Z"
    save_json(d, "reviews.json", reviews)


# === Protocol recovery FIX2 authorization lane mutations (RECOVERY1-FIX2) ===
# Base fixture: advance_protocol_recovery_fix2_authorization.

def _fix2_comment(d):
    return load_json(d, "comment.json")


def _fix2_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return load_policy()


def _fix2_save_policy(d, p):
    save_json(d, "policy.json", p)


def _fix2_jobs(d):
    return load_json(d, "jobs.json")


def m_protocol_recovery_fix2_auth_missing(d):
    path = os.path.join(d, "comment.json")
    if os.path.exists(path):
        os.remove(path)


def m_protocol_recovery_fix2_auth_edited(d):
    c = _fix2_comment(d)
    c["updated_at"] = "2026-08-08T09:23:00Z"
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix2_auth_marker_duplicated(d):
    c = _fix2_comment(d)
    c["body"] = FIX2_MARKER + "\n" + c["body"]
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix2_auth_json_duplicated(d):
    c = _fix2_comment(d)
    lead, _, rest = c["body"].partition(FIX2_MARKER)
    c["body"] = lead + FIX2_MARKER + "\n```json\n{}\n```\n" + rest
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix2_auth_policy_mismatch(d):
    p = _fix2_policy(d)
    p["protocol_recovery_fix2_authorization"]["required_workstream"] = "U1R18-R12-WRONG-FIX2"
    _fix2_save_policy(d, p)


def m_protocol_recovery_fix2_auth_after_child(d):
    c = _fix2_comment(d)
    c["created_at"] = "2026-08-08T09:40:00Z"
    c["updated_at"] = "2026-08-08T09:40:00Z"
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix2_auth_unsafe_authorization(d):
    c = _fix2_comment(d)
    c["body"] = c["body"].replace('"ready_authorized": false', '"ready_authorized": true')
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix2_wrong_parent(d):
    head = _fix_head(d)
    head["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)
    p = _fix2_policy(d)
    p["protocol_recovery_fix2_authorization"]["parent_sha"] = WRONG_SHA
    _fix2_save_policy(d, p)
    c = _fix2_comment(d)
    c["body"] = c["body"].replace(FIX2_PARENT_SHA, WRONG_SHA)
    save_json(d, "comment.json", c)
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = "ci: not the fix2 parent\n\nWorkstream: U1R18-R12-UNRELATED"
    save_json(d, "commit_PARENT.json", parent)


def m_protocol_recovery_fix2_wrong_subject(d):
    head = _fix_head(d)
    head["commit"]["message"] = "ci: wrong subject\n\nWorkstream: %s" % FIX2_WORKSTREAM
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix2_wrong_workstream(d):
    head = _fix_head(d)
    head["commit"]["message"] = FIX2_SUBJECT + "\n\nWorkstream: U1R18-R12-WRONG-FIX2"
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix2_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/fix2/extra.txt")
    save_json(d, "files.json", files)


def m_protocol_recovery_fix2_second_child(d):
    p = _fix2_policy(d)
    p["protocol_recovery_fix2_authorization"]["single_direct_child_only"] = False
    _fix2_save_policy(d, p)
    c = _fix2_comment(d)
    c["body"] = c["body"].replace('"single_direct_child_only": true',
                                  '"single_direct_child_only": false')
    save_json(d, "comment.json", c)


def m_protocol_recovery_fix2_parent_advance_missing(d):
    runs = _fix_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != FIX2_PARENT_ADVANCE_RUN]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix2_parent_advance_not_success(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX2_PARENT_ADVANCE_RUN:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix2_parent_advance_job_missing(d):
    data = _fix2_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    jobs = [j for j in jobs if j.get("id") != FIX2_PARENT_ADVANCE_JOB]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix2_parent_advance_job_not_success(d):
    data = _fix2_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    for j in jobs:
        if j.get("id") == FIX2_PARENT_ADVANCE_JOB:
            j["conclusion"] = "failure"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix2_parent_advance_wrong_head(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX2_PARENT_ADVANCE_RUN:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix2_parent_advance_state_wrong(d):
    logs = _fix_job_logs(d)
    key = str(FIX2_PARENT_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace('"state": "CURRENT_WORKSTREAM_ACTIVE"',
                                      '"state": "REJECTED"')
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix2_parent_advance_authority_wrong(d):
    logs = _fix_job_logs(d)
    key = str(FIX2_PARENT_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace('"parent_authority": "%s"' % FIX2_PARENT_ADVANCE_AUTHORITY,
                                      '"parent_authority": "wrong_authority"')
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix2_parent_advance_state_head_wrong(d):
    logs = _fix_job_logs(d)
    key = str(FIX2_PARENT_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace(FIX2_PARENT_SHA, WRONG_SHA)
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix2_parent_core_ci_missing(d):
    runs = _fix_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != FIX2_PARENT_CORE_CI_RUN]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix2_parent_core_ci_not_success(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == FIX2_PARENT_CORE_CI_RUN:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix2_parent_core_ci_job_not_success(d):
    data = _fix2_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    for j in jobs:
        if j.get("run_id") == FIX2_PARENT_CORE_CI_RUN:
            j["conclusion"] = "failure"
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix2_parent_core_ci_required_jobs_missing(d):
    data = _fix2_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    jobs = [j for j in jobs
            if not (j.get("run_id") == FIX2_PARENT_CORE_CI_RUN
                    and j.get("name") == "Swift Build")]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix2_chronology_wrong(d):
    c = _fix2_comment(d)
    c["created_at"] = "2026-08-08T08:00:00Z"
    c["updated_at"] = "2026-08-08T08:00:00Z"
    save_json(d, "comment.json", c)


# === Protocol recovery FIX3 authorization mutations (RECOVERY1-FIX3) ===
# Base fixture: advance_protocol_recovery_fix3_authorization.

def _fix3_auth_file():
    return "comment_%d.json" % RECOVERY_FIX3_COMMENT_ID


def _fix3_report_file():
    return "comment_%d.json" % RECOVERY_FIX3_REPORT_ID


def _fix3_comment(d):
    return load_json(d, _fix3_auth_file())


def _fix3_save_comment(d, c):
    save_json(d, _fix3_auth_file(), c)


def _fix3_report(d):
    return load_json(d, _fix3_report_file())


def _fix3_save_report(d, c):
    save_json(d, _fix3_report_file(), c)


def _fix3_policy(d):
    path = os.path.join(d, "policy.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return load_policy()


def _fix3_save_policy(d, p):
    save_json(d, "policy.json", p)


def _fix3_jobs(d):
    return load_json(d, "jobs.json")


def m_protocol_recovery_fix3_auth_missing(d):
    path = os.path.join(d, _fix3_auth_file())
    if os.path.exists(path):
        os.remove(path)


def m_protocol_recovery_fix3_auth_edited(d):
    c = _fix3_comment(d)
    c["updated_at"] = "2026-08-08T12:03:00Z"
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_auth_wrong_kind(d):
    c = _fix3_comment(d)
    c["body"] = c["body"].replace('"kind": "protocol_recovery_fix3_authorization"',
                                  '"kind": "wrong_kind"')
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_auth_policy_mismatch(d):
    p = _fix3_policy(d)
    p["protocol_recovery_fix3_authorization"]["required_workstream"] = "U1R18-R12-WRONG-FIX3"
    _fix3_save_policy(d, p)


def m_protocol_recovery_fix3_auth_required_fixes_mismatch(d):
    p = _fix3_policy(d)
    p["protocol_recovery_fix3_authorization"]["required_fixes"] = ["wrong_fix"]
    _fix3_save_policy(d, p)


def m_protocol_recovery_fix3_auth_wrong_classification(d):
    c = _fix3_comment(d)
    c["body"] = re.sub(r'"sai_technical_classification": "[^"]*"',
                       '"sai_technical_classification": null', c["body"])
    _fix3_save_comment(d, c)
    p = _fix3_policy(d)
    p["protocol_recovery_fix3_authorization"]["sai_technical_classification"] = None
    _fix3_save_policy(d, p)


def m_protocol_recovery_fix3_auth_after_child(d):
    c = _fix3_comment(d)
    c["created_at"] = "2026-08-08T12:20:00Z"
    c["updated_at"] = "2026-08-08T12:20:00Z"
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_ready_authorized(d):
    c = _fix3_comment(d)
    c["body"] = c["body"].replace('"ready_authorized": false', '"ready_authorized": true')
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_merge_authorized(d):
    c = _fix3_comment(d)
    c["body"] = c["body"].replace('"merge_authorized": false', '"merge_authorized": true')
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_release_authorized(d):
    c = _fix3_comment(d)
    c["body"] = c["body"].replace('"release_authorized": false', '"release_authorized": true')
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_wrong_parent(d):
    head = _fix_head(d)
    head["parents"] = [{"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)
    p = _fix3_policy(d)
    p["protocol_recovery_fix3_authorization"]["parent_sha"] = WRONG_SHA
    _fix3_save_policy(d, p)
    c = _fix3_comment(d)
    c["body"] = c["body"].replace(RECOVERY_FIX3_PARENT_SHA, WRONG_SHA)
    _fix3_save_comment(d, c)
    parent = load_json(d, "commit_PARENT.json")
    parent["commit"]["message"] = "ci: not the fix3 parent\n\nWorkstream: U1R18-R12-UNRELATED"
    save_json(d, "commit_PARENT.json", parent)


def m_protocol_recovery_fix3_wrong_subject(d):
    head = _fix_head(d)
    head["commit"]["message"] = "ci: wrong subject\n\nWorkstream: %s" % RECOVERY_FIX3_WORKSTREAM
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix3_wrong_workstream(d):
    head = _fix_head(d)
    head["commit"]["message"] = RECOVERY_FIX3_SUBJECT + "\n\nWorkstream: U1R18-R12-WRONG-FIX3"
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix3_merge_commit(d):
    head = _fix_head(d)
    head["parents"] = [{"sha": RECOVERY_FIX3_PARENT_SHA}, {"sha": WRONG_SHA}]
    save_json(d, "commit_HEAD.json", head)


def m_protocol_recovery_fix3_forbidden_path(d):
    files = _bridge_files(d)
    files.append("unknown/fix3/extra.txt")
    save_json(d, "files.json", files)


def m_protocol_recovery_fix3_second_child(d):
    p = _fix3_policy(d)
    p["protocol_recovery_fix3_authorization"]["single_direct_child_only"] = False
    _fix3_save_policy(d, p)
    c = _fix3_comment(d)
    c["body"] = c["body"].replace('"single_direct_child_only": true',
                                  '"single_direct_child_only": false')
    _fix3_save_comment(d, c)


def m_protocol_recovery_fix3_parent_report_missing(d):
    c = _fix3_report(d)
    c["body"] = ""
    _fix3_save_report(d, c)


def m_protocol_recovery_fix3_parent_report_wrong_head(d):
    c = _fix3_report(d)
    c["body"] = c["body"].replace(RECOVERY_FIX3_PARENT_SHA, WRONG_SHA)
    _fix3_save_report(d, c)


def m_protocol_recovery_fix3_parent_report_wrong_workstream(d):
    c = _fix3_report(d)
    c["body"] = c["body"].replace(RECOVERY_FIX3_PARENT_WORKSTREAM, "U1R18-R12-WRONG-FIX3")
    _fix3_save_report(d, c)


def m_protocol_recovery_fix3_parent_advance_missing(d):
    runs = _fix_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != RECOVERY_FIX3_PARENT_ADVANCE_RUN]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix3_parent_advance_wrong_head(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == RECOVERY_FIX3_PARENT_ADVANCE_RUN:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix3_parent_advance_wrong_state(d):
    logs = _fix_job_logs(d)
    key = str(RECOVERY_FIX3_PARENT_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace('"state": "%s"' % RECOVERY_FIX3_PARENT_ADVANCE_STATE,
                                      '"state": "REJECTED"')
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix3_parent_advance_wrong_authority(d):
    logs = _fix_job_logs(d)
    key = str(RECOVERY_FIX3_PARENT_ADVANCE_JOB)
    if key in logs:
        logs[key] = logs[key].replace(
            '"parent_authority": "%s"' % RECOVERY_FIX3_PARENT_ADVANCE_AUTHORITY,
            '"parent_authority": "wrong_authority"')
    save_json(d, "job-logs.json", logs)


def m_protocol_recovery_fix3_parent_ci_missing(d):
    runs = _fix_runs(d)
    runs["workflow_runs"] = [r for r in runs.get("workflow_runs", [])
                             if r.get("id") != RECOVERY_FIX3_PARENT_CORE_CI_RUN]
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix3_parent_ci_wrong_head(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == RECOVERY_FIX3_PARENT_CORE_CI_RUN:
            r["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix3_parent_ci_job_missing(d):
    data = _fix3_jobs(d)
    jobs = data.get("jobs", []) if isinstance(data, dict) else data
    jobs = [j for j in jobs
            if not (j.get("run_id") == RECOVERY_FIX3_PARENT_CORE_CI_RUN
                    and j.get("name") == "Swift Build")]
    save_json(d, "jobs.json", {"total_count": len(jobs), "jobs": jobs})


def m_protocol_recovery_fix3_parent_ci_red(d):
    runs = _fix_runs(d)
    for r in runs.get("workflow_runs", []):
        if r.get("id") == RECOVERY_FIX3_PARENT_CORE_CI_RUN:
            r["conclusion"] = "failure"
    save_json(d, "runs.json", runs)


def m_protocol_recovery_fix3_chronology_wrong(d):
    c = _fix3_comment(d)
    c["created_at"] = "2026-08-08T11:00:00Z"
    c["updated_at"] = "2026-08-08T11:00:00Z"
    _fix3_save_comment(d, c)


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
    "red_source_auth_comment_missing": m_red_source_auth_comment_missing,
    "red_source_auth_comment_edited": m_red_source_auth_comment_edited,
    "red_source_auth_marker_duplicated": m_red_source_auth_marker_duplicated,
    "red_source_auth_json_duplicated": m_red_source_auth_json_duplicated,
    "red_source_auth_schema_mismatch": m_red_source_auth_schema_mismatch,
    "red_source_auth_policy_mismatch": m_red_source_auth_policy_mismatch,
    "red_source_auth_unsafe_authorization": m_red_source_auth_unsafe_authorization,
    "red_source_fix_wrong_parent": m_red_source_fix_wrong_parent,
    "red_source_fix_wrong_subject": m_red_source_fix_wrong_subject,
    "red_source_fix_wrong_workstream": m_red_source_fix_wrong_workstream,
    "red_source_fix_forbidden_path": m_red_source_fix_forbidden_path,
    "red_source_fix_no_changed_files": m_red_source_fix_no_changed_files,
    "red_source_ci_wrong_sha": m_red_source_ci_wrong_sha,
    "red_source_ci_failed": m_red_source_ci_failed,
    "red_source_ci_required_job_missing": m_red_source_ci_required_job_missing,
    "red_bridge_wrong_subject": m_red_bridge_wrong_subject,
    "red_bridge_wrong_workstream": m_red_bridge_wrong_workstream,
    "red_bridge_forbidden_path": m_red_bridge_forbidden_path,

# === GATE1-FIX1: rejected controller review binding ===
    "red_bridge_rejected_review_missing": m_red_bridge_rejected_review_missing,
    "red_bridge_rejected_review_wrong_id": m_red_bridge_rejected_review_wrong_id,
    "red_bridge_rejected_review_wrong_commit": m_red_bridge_rejected_review_wrong_commit,
    "red_bridge_rejected_review_wrong_decision": m_red_bridge_rejected_review_wrong_decision,
    "red_bridge_rejected_review_wrong_classification": m_red_bridge_rejected_review_wrong_classification,
    "red_bridge_rejected_review_incomplete": m_red_bridge_rejected_review_incomplete,
    "red_bridge_rejected_review_nx_false": m_red_bridge_rejected_review_nx_false,
    "red_bridge_rejected_review_ready_true": m_red_bridge_rejected_review_ready_true,
    "red_bridge_rejected_review_merge_true": m_red_bridge_rejected_review_merge_true,
    "red_bridge_rejected_review_release_true": m_red_bridge_rejected_review_release_true,
    "red_bridge_rejected_review_after_source_fix": m_red_bridge_rejected_review_after_source_fix,

# === GATE1-FIX1: failed advance binding ===
    "red_failed_advance_incomplete": m_red_failed_advance_incomplete,
    "red_failed_advance_success": m_red_failed_advance_success,
    "red_failed_advance_job_missing": m_red_failed_advance_job_missing,
    "red_failed_advance_job_success": m_red_failed_advance_job_success,
    "red_failed_advance_guard_missing": m_red_failed_advance_guard_missing,
    "red_failed_advance_guard_mismatch": m_red_failed_advance_guard_mismatch,
    "red_failed_advance_wrong_head": m_red_failed_advance_wrong_head,
    "red_failed_advance_wrong_parent": m_red_failed_advance_wrong_parent,

# === GATE1-FIX1: source auth chronology ===
    "red_source_auth_after_bridge": m_red_source_auth_after_bridge,

# === GATE1-FIX1: gate-fix authorization lane ===
    "gate_fix_auth_missing": m_gate_fix_auth_missing,
    "gate_fix_auth_edited": m_gate_fix_auth_edited,
    "gate_fix_auth_marker_duplicated": m_gate_fix_auth_marker_duplicated,
    "gate_fix_auth_json_duplicated": m_gate_fix_auth_json_duplicated,
    "gate_fix_auth_policy_mismatch": m_gate_fix_auth_policy_mismatch,
    "gate_fix_auth_after_child": m_gate_fix_auth_after_child,
    "gate_fix_wrong_parent": m_gate_fix_wrong_parent,
    "gate_fix_wrong_subject": m_gate_fix_wrong_subject,
    "gate_fix_wrong_workstream": m_gate_fix_wrong_workstream,
    "gate_fix_forbidden_path": m_gate_fix_forbidden_path,
    "gate_fix_reused_by_grandchild": m_gate_fix_reused_by_grandchild,
    "gate_fix_ready_true": m_gate_fix_ready_true,
    "gate_fix_merge_true": m_gate_fix_merge_true,
    "gate_fix_release_true": m_gate_fix_release_true,

# === R12-FIX3-GATE1: red parent source fix CHAIN bridge ===
    "red_chain_auth_comment_missing": m_red_chain_auth_comment_missing,
    "red_chain_auth_comment_edited": m_red_chain_auth_comment_edited,
    "red_chain_auth_after_bridge": m_red_chain_auth_after_bridge,
    "red_chain_auth_marker_duplicated": m_red_chain_auth_marker_duplicated,
    "red_chain_auth_json_duplicated": m_red_chain_auth_json_duplicated,
    "red_chain_auth_schema_mismatch": m_red_chain_auth_schema_mismatch,
    "red_chain_auth_policy_mismatch": m_red_chain_auth_policy_mismatch,
    "red_chain_auth_unsafe_authorization": m_red_chain_auth_unsafe_authorization,
    "red_chain_auth_single_child_required": m_red_chain_auth_single_child_required,
    "red_chain_auth_chain_length_mismatch": m_red_chain_auth_chain_length_mismatch,
    "red_chain_wrong_root": m_red_chain_wrong_root,
    "red_chain_wrong_link": m_red_chain_wrong_link,
    "red_chain_wrong_terminal": m_red_chain_wrong_terminal,
    "red_chain_fix1_wrong_parent": m_red_chain_fix1_wrong_parent,
    "red_chain_fix1_wrong_subject": m_red_chain_fix1_wrong_subject,
    "red_chain_fix1_wrong_workstream": m_red_chain_fix1_wrong_workstream,
    "red_chain_fix1_forbidden_path": m_red_chain_fix1_forbidden_path,
    "red_chain_fix1_no_changed_files": m_red_chain_fix1_no_changed_files,
    "red_chain_ci_wrong_sha": m_red_chain_ci_wrong_sha,
    "red_chain_ci_failed": m_red_chain_ci_failed,
    "red_chain_ci_required_job_missing": m_red_chain_ci_required_job_missing,
    "red_chain_advance_incomplete": m_red_chain_advance_incomplete,
    "red_chain_advance_not_failed": m_red_chain_advance_not_failed,
    "red_chain_advance_job_missing": m_red_chain_advance_job_missing,
    "red_chain_advance_job_not_failed": m_red_chain_advance_job_not_failed,
    "red_chain_advance_guard_missing": m_red_chain_advance_guard_missing,
    "red_chain_advance_guard_mismatch": m_red_chain_advance_guard_mismatch,
    "red_chain_advance_wrong_head": m_red_chain_advance_wrong_head,
    "red_chain_advance_wrong_parent": m_red_chain_advance_wrong_parent,
    "red_chain_bridge_no_changed_files": m_red_chain_bridge_no_changed_files,
    "red_chain_bridge_forbidden_path": m_red_chain_bridge_forbidden_path,
    "red_chain_bridge_wrong_subject": m_red_chain_bridge_wrong_subject,
    "red_chain_bridge_wrong_workstream": m_red_chain_bridge_wrong_workstream,
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

# === GATE1-RECOVERY1: protocol recovery authorization lane ===
    "protocol_recovery_corrective_review_missing": m_protocol_recovery_corrective_review_missing,
    "protocol_recovery_corrective_review_wrong_classification": m_protocol_recovery_corrective_review_wrong_classification,
    "protocol_recovery_corrective_review_quarantined": m_protocol_recovery_corrective_review_quarantined,
    "protocol_recovery_unauthorized_review_missing": m_protocol_recovery_unauthorized_review_missing,
    "protocol_recovery_unauthorized_review_not_quarantined": m_protocol_recovery_unauthorized_review_not_quarantined,
    "protocol_recovery_review_run_missing": m_protocol_recovery_review_run_missing,
    "protocol_recovery_review_run_not_success": m_protocol_recovery_review_run_not_success,
    "protocol_recovery_review_run_wrong_head": m_protocol_recovery_review_run_wrong_head,
    "protocol_recovery_review_run_not_quarantined": m_protocol_recovery_review_run_not_quarantined,
    "protocol_recovery_review_job_not_success": m_protocol_recovery_review_job_not_success,
    "protocol_recovery_review_run_final_state_wrong": m_protocol_recovery_review_run_final_state_wrong,
    "protocol_recovery_chronology_wrong": m_protocol_recovery_chronology_wrong,
    "protocol_recovery_wrong_parent": m_protocol_recovery_wrong_parent,
    "protocol_recovery_wrong_subject": m_protocol_recovery_wrong_subject,
    "protocol_recovery_wrong_workstream": m_protocol_recovery_wrong_workstream,
    "protocol_recovery_forbidden_path": m_protocol_recovery_forbidden_path,
    "protocol_recovery_merge_commit": m_protocol_recovery_merge_commit,
    "protocol_recovery_ready_true": m_protocol_recovery_ready_true,
    "protocol_recovery_merge_true": m_protocol_recovery_merge_true,
    "protocol_recovery_release_true": m_protocol_recovery_release_true,
    "protocol_recovery_second_child": m_protocol_recovery_second_child,

# === GATE1-RECOVERY1-FIX1: protocol recovery fix authorization lane ===
    "protocol_recovery_fix_auth_missing": m_protocol_recovery_fix_auth_missing,
    "protocol_recovery_fix_auth_edited": m_protocol_recovery_fix_auth_edited,
    "protocol_recovery_fix_auth_marker_duplicated": m_protocol_recovery_fix_auth_marker_duplicated,
    "protocol_recovery_fix_auth_json_duplicated": m_protocol_recovery_fix_auth_json_duplicated,
    "protocol_recovery_fix_auth_policy_mismatch": m_protocol_recovery_fix_auth_policy_mismatch,
    "protocol_recovery_fix_auth_after_child": m_protocol_recovery_fix_auth_after_child,
    "protocol_recovery_fix_auth_unsafe_authorization": m_protocol_recovery_fix_auth_unsafe_authorization,
    "protocol_recovery_fix_wrong_parent": m_protocol_recovery_fix_wrong_parent,
    "protocol_recovery_fix_wrong_subject": m_protocol_recovery_fix_wrong_subject,
    "protocol_recovery_fix_wrong_workstream": m_protocol_recovery_fix_wrong_workstream,
    "protocol_recovery_fix_forbidden_path": m_protocol_recovery_fix_forbidden_path,
    "protocol_recovery_fix_second_child": m_protocol_recovery_fix_second_child,
    "protocol_recovery_fix_failed_advance_missing": m_protocol_recovery_fix_failed_advance_missing,
    "protocol_recovery_fix_failed_advance_not_failed": m_protocol_recovery_fix_failed_advance_not_failed,
    "protocol_recovery_fix_failed_advance_job_missing": m_protocol_recovery_fix_failed_advance_job_missing,
    "protocol_recovery_fix_failed_advance_job_not_failed": m_protocol_recovery_fix_failed_advance_job_not_failed,
    "protocol_recovery_fix_failed_advance_guard_missing": m_protocol_recovery_fix_failed_advance_guard_missing,
    "protocol_recovery_fix_failed_advance_guard_mismatch": m_protocol_recovery_fix_failed_advance_guard_mismatch,
    "protocol_recovery_fix_failed_advance_wrong_head": m_protocol_recovery_fix_failed_advance_wrong_head,
    "protocol_recovery_fix_failed_advance_wrong_parent": m_protocol_recovery_fix_failed_advance_wrong_parent,
    "protocol_recovery_fix_review_gate_run_missing": m_protocol_recovery_fix_review_gate_run_missing,
    "protocol_recovery_fix_review_gate_run_not_success": m_protocol_recovery_fix_review_gate_run_not_success,
    "protocol_recovery_fix_review_gate_wrong_head": m_protocol_recovery_fix_review_gate_wrong_head,
    "protocol_recovery_fix_review_gate_job_missing": m_protocol_recovery_fix_review_gate_job_missing,
    "protocol_recovery_fix_review_gate_job_not_success": m_protocol_recovery_fix_review_gate_job_not_success,
    "protocol_recovery_fix_review_gate_final_state_missing": m_protocol_recovery_fix_review_gate_final_state_missing,
    "protocol_recovery_fix_review_gate_final_state_wrong": m_protocol_recovery_fix_review_gate_final_state_wrong,
    "protocol_recovery_fix_review_gate_final_state_untimestamped": m_protocol_recovery_fix_review_gate_final_state_untimestamped,
    "protocol_recovery_fix_review_gate_final_state_outside_window": m_protocol_recovery_fix_review_gate_final_state_outside_window,
    "protocol_recovery_fix_corrective_review_missing": m_protocol_recovery_fix_corrective_review_missing,
    "protocol_recovery_fix_corrective_review_not_rejected": m_protocol_recovery_fix_corrective_review_not_rejected,
    "protocol_recovery_fix_corrective_review_wrong_classification": m_protocol_recovery_fix_corrective_review_wrong_classification,
    "protocol_recovery_fix_corrective_review_quarantined": m_protocol_recovery_fix_corrective_review_quarantined,
    "protocol_recovery_fix_corrective_review_incomplete": m_protocol_recovery_fix_corrective_review_incomplete,
    "protocol_recovery_fix_unsafe_authorization": m_protocol_recovery_fix_unsafe_authorization,
    "protocol_recovery_fix_chronology_wrong": m_protocol_recovery_fix_chronology_wrong,

# === GATE1-RECOVERY1-FIX2: protocol recovery fix2 authorization lane ===
    "protocol_recovery_fix2_auth_missing": m_protocol_recovery_fix2_auth_missing,
    "protocol_recovery_fix2_auth_edited": m_protocol_recovery_fix2_auth_edited,
    "protocol_recovery_fix2_auth_marker_duplicated": m_protocol_recovery_fix2_auth_marker_duplicated,
    "protocol_recovery_fix2_auth_json_duplicated": m_protocol_recovery_fix2_auth_json_duplicated,
    "protocol_recovery_fix2_auth_policy_mismatch": m_protocol_recovery_fix2_auth_policy_mismatch,
    "protocol_recovery_fix2_auth_after_child": m_protocol_recovery_fix2_auth_after_child,
    "protocol_recovery_fix2_auth_unsafe_authorization": m_protocol_recovery_fix2_auth_unsafe_authorization,
    "protocol_recovery_fix2_wrong_parent": m_protocol_recovery_fix2_wrong_parent,
    "protocol_recovery_fix2_wrong_subject": m_protocol_recovery_fix2_wrong_subject,
    "protocol_recovery_fix2_wrong_workstream": m_protocol_recovery_fix2_wrong_workstream,
    "protocol_recovery_fix2_forbidden_path": m_protocol_recovery_fix2_forbidden_path,
    "protocol_recovery_fix2_second_child": m_protocol_recovery_fix2_second_child,
    "protocol_recovery_fix2_parent_advance_missing": m_protocol_recovery_fix2_parent_advance_missing,
    "protocol_recovery_fix2_parent_advance_not_success": m_protocol_recovery_fix2_parent_advance_not_success,
    "protocol_recovery_fix2_parent_advance_job_missing": m_protocol_recovery_fix2_parent_advance_job_missing,
    "protocol_recovery_fix2_parent_advance_job_not_success": m_protocol_recovery_fix2_parent_advance_job_not_success,
    "protocol_recovery_fix2_parent_advance_wrong_head": m_protocol_recovery_fix2_parent_advance_wrong_head,
    "protocol_recovery_fix2_parent_advance_state_wrong": m_protocol_recovery_fix2_parent_advance_state_wrong,
    "protocol_recovery_fix2_parent_advance_authority_wrong": m_protocol_recovery_fix2_parent_advance_authority_wrong,
    "protocol_recovery_fix2_parent_advance_state_head_wrong": m_protocol_recovery_fix2_parent_advance_state_head_wrong,
    "protocol_recovery_fix2_parent_core_ci_missing": m_protocol_recovery_fix2_parent_core_ci_missing,
    "protocol_recovery_fix2_parent_core_ci_not_success": m_protocol_recovery_fix2_parent_core_ci_not_success,
    "protocol_recovery_fix2_parent_core_ci_job_not_success": m_protocol_recovery_fix2_parent_core_ci_job_not_success,
    "protocol_recovery_fix2_parent_core_ci_required_jobs_missing": m_protocol_recovery_fix2_parent_core_ci_required_jobs_missing,
    "protocol_recovery_fix2_chronology_wrong": m_protocol_recovery_fix2_chronology_wrong,
    "protocol_recovery_fix3_auth_missing": m_protocol_recovery_fix3_auth_missing,
    "protocol_recovery_fix3_auth_edited": m_protocol_recovery_fix3_auth_edited,
    "protocol_recovery_fix3_auth_wrong_kind": m_protocol_recovery_fix3_auth_wrong_kind,
    "protocol_recovery_fix3_auth_policy_mismatch": m_protocol_recovery_fix3_auth_policy_mismatch,
    "protocol_recovery_fix3_auth_required_fixes_mismatch": m_protocol_recovery_fix3_auth_required_fixes_mismatch,
    "protocol_recovery_fix3_auth_wrong_classification": m_protocol_recovery_fix3_auth_wrong_classification,
    "protocol_recovery_fix3_auth_after_child": m_protocol_recovery_fix3_auth_after_child,
    "protocol_recovery_fix3_ready_authorized": m_protocol_recovery_fix3_ready_authorized,
    "protocol_recovery_fix3_merge_authorized": m_protocol_recovery_fix3_merge_authorized,
    "protocol_recovery_fix3_release_authorized": m_protocol_recovery_fix3_release_authorized,
    "protocol_recovery_fix3_wrong_parent": m_protocol_recovery_fix3_wrong_parent,
    "protocol_recovery_fix3_wrong_subject": m_protocol_recovery_fix3_wrong_subject,
    "protocol_recovery_fix3_wrong_workstream": m_protocol_recovery_fix3_wrong_workstream,
    "protocol_recovery_fix3_merge_commit": m_protocol_recovery_fix3_merge_commit,
    "protocol_recovery_fix3_forbidden_path": m_protocol_recovery_fix3_forbidden_path,
    "protocol_recovery_fix3_second_child": m_protocol_recovery_fix3_second_child,
    "protocol_recovery_fix3_parent_report_missing": m_protocol_recovery_fix3_parent_report_missing,
    "protocol_recovery_fix3_parent_report_wrong_head": m_protocol_recovery_fix3_parent_report_wrong_head,
    "protocol_recovery_fix3_parent_report_wrong_workstream": m_protocol_recovery_fix3_parent_report_wrong_workstream,
    "protocol_recovery_fix3_parent_advance_missing": m_protocol_recovery_fix3_parent_advance_missing,
    "protocol_recovery_fix3_parent_advance_wrong_head": m_protocol_recovery_fix3_parent_advance_wrong_head,
    "protocol_recovery_fix3_parent_advance_wrong_state": m_protocol_recovery_fix3_parent_advance_wrong_state,
    "protocol_recovery_fix3_parent_advance_wrong_authority": m_protocol_recovery_fix3_parent_advance_wrong_authority,
    "protocol_recovery_fix3_parent_ci_missing": m_protocol_recovery_fix3_parent_ci_missing,
    "protocol_recovery_fix3_parent_ci_wrong_head": m_protocol_recovery_fix3_parent_ci_wrong_head,
    "protocol_recovery_fix3_parent_ci_job_missing": m_protocol_recovery_fix3_parent_ci_job_missing,
    "protocol_recovery_fix3_parent_ci_red": m_protocol_recovery_fix3_parent_ci_red,
    "protocol_recovery_fix3_chronology_wrong": m_protocol_recovery_fix3_chronology_wrong,
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
