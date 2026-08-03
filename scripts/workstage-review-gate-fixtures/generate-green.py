#!/usr/bin/env python3
"""Generate GREEN fixture bundles for workshift-review-gate."""

import json
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR)

# SHAs
HEAD_NORMAL = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"
PARENT_NORMAL = "6656ec33d15289ce122f4ba9d1e2db71f260d8b7"
HEAD_BOOTSTRAP = "cafe1234cafe1234cafe1234cafe1234cafe1234"
PARENT_BOOTSTRAP = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"

# Timestamps
COMMIT_DATE_HEAD = "2026-08-03T02:52:13Z"
COMMIT_DATE_PARENT = "2026-08-03T01:53:00Z"
COMMIT_DATE_HEAD_BOOTSTRAP = "2026-08-03T03:00:00Z"
COMMIT_DATE_PARENT_BOOTSTRAP = "2026-08-03T02:30:00Z"

WORKFLOW_RUN_ID = 30780331595
REQUIRED_JOBS = ["Swift Build", "Public Audit", "Recipe Validation", "License Validation", "Gitignore Validation"]

POLICY = {
    "schema_version": 1,
    "repository": "oxcandy-lgtm/macsteam",
    "pr_number": 2,
    "branch": "feat/ultimate-cloverpit-u1",
    "base_branch": "feat/public-oss-bootstrap",
    "bootstrap": {
        "head_sha": HEAD_NORMAL,
        "worker_report_comment_id": 5161887210,
        "controller_review_id": 4840817794,
        "classification": "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"
    },
    "core_ci": {
        "required_jobs": REQUIRED_JOBS
    },
    "max_api_items": 1000
}


def pr_json(head_sha, head_ref="feat/ultimate-cloverpit-u1"):
    return {
        "id": 123456789,
        "number": 2,
        "title": "MacsTeam Ultimate U1R18-R7 NX Dispatch",
        "state": "OPEN",
        "draft": True,
        "merged": False,
        "mergeable": "MERGEABLE",
        "head": {
            "sha": head_sha,
            "ref": head_ref,
            "repo": {"full_name": "oxcandy-lgtm/macsteam", "name": "macsteam"}
        },
        "base": {
            "sha": PARENT_NORMAL,
            "ref": "feat/public-oss-bootstrap",
            "repo": {"full_name": "oxcandy-lgtm/macsteam", "name": "macsteam"}
        }
    }


def commit_head_json(sha, parents, date):
    return {
        "sha": sha,
        "parents": [{"sha": p} for p in parents],
        "commit": {
            "committer": {"date": date},
            "author": {"date": date},
            "message": "ci: enforce workstream review wait gate"
        }
    }


def commit_parent_json(sha, date=COMMIT_DATE_PARENT):
    return {
        "sha": sha,
        "parents": [{"sha": "0000000000000000000000000000000000000000"}],
        "commit": {
            "committer": {"date": date},
            "author": {"date": date},
            "message": "fix: preserve window monitor on duplicate launch rejection (U1R18-FIX1)"
        }
    }


def normal_controller_review(commit_id, submitted_at, classification="GREEN_U1R18_R6_CONTROLLER_REVIEW_ACCEPTED"):
    return {
        "id": 4840817795,
        "user": {"login": "controller"},
        "commit_id": commit_id,
        "state": "APPROVED",
        "body": f"""<!-- macsteam-controller-review:v1 -->
```json
{{
  "schema_version": 1,
  "kind": "controller_review",
  "head_sha": "{commit_id}",
  "decision": "accepted",
  "classification": "{classification}",
  "review_complete": true,
  "nx_required_for_next_workstream": true,
  "ready_authorized": false,
  "merge_authorized": false,
  "release_authorized": false
}}
```
""",
        "submitted_at": submitted_at
    }


def bootstrap_review(submitted_at):
    return {
        "id": 4840817794,
        "user": {"login": "controller"},
        "commit_id": HEAD_NORMAL,
        "state": "APPROVED",
        "body": "Bootstrap review for R3 closure — predates v1 marker protocol.",
        "submitted_at": submitted_at
    }


def worker_report_comment(head_sha, parent_sha, updated_at, run_id=WORKFLOW_RUN_ID):
    report = {
        "schema_version": 1,
        "kind": "worker_report",
        "workstream": "U1R18-R7",
        "head_sha": head_sha,
        "parent_sha": parent_sha,
        "commit_count": 1,
        "core_ci_run_id": run_id,
        "core_ci_jobs": REQUIRED_JOBS,
        "gate_advance_run_id": 30780332001,
        "gate_submission_run_id": 0,
        "stop": True,
        "next_workstream_started": False,
        "ready_performed": False,
        "merge_performed": False,
        "release_performed": False
    }
    return {
        "id": 5161887211,
        "user": {"login": "macsteam-dev"},
        "body": f"""<!-- macsteam-worker-report:v1 -->
```json
{json.dumps(report, indent=2)}
```
""",
        "created_at": updated_at,
        "updated_at": updated_at
    }


def workflow_runs(run_id, head_sha, status="completed", conclusion="success"):
    return {
        "workflow_runs": [
            {
                "id": run_id,
                "head_sha": head_sha,
                "status": status,
                "conclusion": conclusion,
                "name": "CI",
                "created_at": "2026-08-03T02:50:00Z"
            }
        ]
    }


def workflow_jobs(run_id):
    return {
        "jobs": [
            {"name": j, "conclusion": "success", "status": "completed", "run_id": run_id}
            for j in REQUIRED_JOBS
        ]
    }


def write_fixture(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


# === Green advance_normal ===
def create_advance_normal():
    d = os.path.join(FIXTURE_DIR, "green", "advance_normal")
    write_fixture(f"{d}/pr.json", pr_json(HEAD_NORMAL))
    write_fixture(f"{d}/commit_HEAD.json", commit_head_json(HEAD_NORMAL, [PARENT_NORMAL], COMMIT_DATE_HEAD))
    write_fixture(f"{d}/commit_PARENT.json", commit_parent_json(PARENT_NORMAL))
    write_fixture(f"{d}/reviews.json", [normal_controller_review(PARENT_NORMAL, "2026-08-03T02:00:00Z")])
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", [])
    write_fixture(f"{d}/jobs.json", [])


# === Green advance_bootstrap ===
def create_advance_bootstrap():
    d = os.path.join(FIXTURE_DIR, "green", "advance_bootstrap")
    write_fixture(f"{d}/pr.json", pr_json(HEAD_BOOTSTRAP))
    write_fixture(f"{d}/commit_HEAD.json", commit_head_json(HEAD_BOOTSTRAP, [PARENT_BOOTSTRAP], COMMIT_DATE_HEAD_BOOTSTRAP))
    write_fixture(f"{d}/commit_PARENT.json", commit_parent_json(PARENT_BOOTSTRAP, COMMIT_DATE_PARENT_BOOTSTRAP))
    write_fixture(f"{d}/reviews.json", [bootstrap_review("2026-08-03T02:45:00Z")])
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", [])
    write_fixture(f"{d}/jobs.json", [])


# === Green submission ===
def create_submission():
    d = os.path.join(FIXTURE_DIR, "green", "submission")
    write_fixture(f"{d}/pr.json", pr_json(HEAD_NORMAL))
    write_fixture(f"{d}/commit_HEAD.json", commit_head_json(HEAD_NORMAL, [PARENT_NORMAL], COMMIT_DATE_HEAD))
    write_fixture(f"{d}/commit_PARENT.json", commit_parent_json(PARENT_NORMAL))
    write_fixture(f"{d}/reviews.json", [normal_controller_review(PARENT_NORMAL, "2026-08-03T02:00:00Z")])
    write_fixture(f"{d}/comments.json", [worker_report_comment(HEAD_NORMAL, PARENT_NORMAL, "2026-08-03T02:53:00Z")])
    write_fixture(f"{d}/runs.json", workflow_runs(WORKFLOW_RUN_ID, HEAD_NORMAL))
    write_fixture(f"{d}/jobs.json", workflow_jobs(WORKFLOW_RUN_ID))


# === Green review ===
def create_review():
    d = os.path.join(FIXTURE_DIR, "green", "review")
    write_fixture(f"{d}/pr.json", pr_json(HEAD_NORMAL))
    write_fixture(f"{d}/commit_HEAD.json", commit_head_json(HEAD_NORMAL, [PARENT_NORMAL], COMMIT_DATE_HEAD))
    write_fixture(f"{d}/commit_PARENT.json", commit_parent_json(PARENT_NORMAL))
    write_fixture(f"{d}/reviews.json", [
        normal_controller_review(PARENT_NORMAL, "2026-08-03T02:00:00Z", "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"),
        {
            "id": 4840817796,
            "user": {"login": "controller"},
            "commit_id": HEAD_NORMAL,
            "state": "APPROVED",
            "body": f"""<!-- macsteam-controller-review:v1 -->
```json
{{
  "schema_version": 1,
  "kind": "controller_review",
  "head_sha": "{HEAD_NORMAL}",
  "decision": "accepted",
  "classification": "GREEN_U1R18_R7_CONTROLLER_REVIEW_ACCEPTED",
  "review_complete": true,
  "nx_required_for_next_workstream": true,
  "ready_authorized": false,
  "merge_authorized": false,
  "release_authorized": false
}}
```
""",
            "submitted_at": "2026-08-03T02:55:00Z"
        }
    ])
    write_fixture(f"{d}/comments.json", [worker_report_comment(HEAD_NORMAL, PARENT_NORMAL, "2026-08-03T02:53:00Z")])
    write_fixture(f"{d}/runs.json", workflow_runs(WORKFLOW_RUN_ID, HEAD_NORMAL))
    write_fixture(f"{d}/jobs.json", workflow_jobs(WORKFLOW_RUN_ID))


if __name__ == "__main__":
    create_advance_normal()
    create_advance_bootstrap()
    create_submission()
    create_review()
    print("GREEN fixtures created.")
