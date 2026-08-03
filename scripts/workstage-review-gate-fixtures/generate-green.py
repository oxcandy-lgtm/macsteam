#!/usr/bin/env python3
"""Generate GREEN fixture bundles for workstage-review-gate — U1R18-R7-FIX1.

Creates all GREEN fixture directories that should pass the gate with exit code 0.
"""

import json
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR)

# === SHA constants ===
BOOTSTRAP_HEAD = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"
R7_HEAD = "f3ae89d2caa07930ffda7a84059ecdfb18942e3d"
FIX1_HEAD = "fe1234567890abcdef1234567890abcdef123456"
NORMAL_PARENT = "6656ec33d15289ce122f4ba9d1e2db71f260d8b7"
NORMAL_HEAD = "0123456789abcdef0123456789abcdef01234567"
HISTORICAL_HEAD = "9999999999999999999999999999999999999999"
HISTORICAL_PARENT = "8888888888888888888888888888888888888888"
WRONG_SHA = "cafe1234cafe1234cafe1234cafe1234cafe1234"

# === Timestamps (all ISO 8601 with Z) ===
PARENT_REVIEW_TS = "2026-08-03T02:00:00Z"
BOOTSTRAP_REVIEW_TS = "2026-08-03T02:45:00Z"
REPAIR_REVIEW_TS = "2026-08-03T02:50:00Z"
HEAD_COMMIT_TS = "2026-08-03T03:00:00Z"
WORKER_REPORT_CREATED = "2026-08-03T03:10:00Z"
WORKER_REPORT_UPDATED = "2026-08-03T03:10:00Z"
HEAD_REVIEW_TS = "2026-08-03T03:15:00Z"
LATEST_ACCEPT_TS = "2026-08-03T03:20:00Z"
REJECTED_REVIEW_TS = "2026-08-03T03:15:00Z"

# === IDs ===
CI_RUN_ID = 30790400001
GATE_ADVANCE_RUN_ID = 30790400002
GATE_SUBMISSION_RUN_ID = 30790400003
BOOTSTRAP_REVIEW_ID = 4840817794
REPAIR_REVIEW_ID = 4841397951
NORMAL_REVIEW_ID = 4840817795
HEAD_REVIEW_ID = 4840817796
QUARANTINED_REVIEW_ID = 4841357081
LATEST_ACCEPT_REVIEW_ID = 4840817797

REQUIRED_JOBS = ["Swift Build", "Public Audit", "Recipe Validation", "License Validation", "Gitignore Validation"]

REPAIR_COMMIT_MSG = "ci: close workstream review authority gate (U1R18-R7-FIX1)\n\nWorkstream: U1R18-R7-FIX1"
REPAIR_CLASSIFICATION = "RED_U1R18_R7_SELF_REVIEW_AND_SEQUENTIAL_GATE_FAIL_OPEN"
BOOTSTRAP_CLASSIFICATION = "GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED"
NORMAL_CLASSIFICATION = "GREEN_U1R18_R6_CONTROLLER_REVIEW_ACCEPTED"
FIX1_WORKSTREAM = "U1R18-R7-FIX1"

ALLOWED_FILES = [
    ".github/workflows/ci.yml",
    ".github/workflows/workstage-review-gate.yml",
    ".github/workstage-review-gate-policy.json",
    "Contracts/controller-review.schema.json",
    "Contracts/workstream-report.schema.json",
    "docs/WORKSTREAM_REVIEW_GATE.md",
    "scripts/workstage-review-gate.py",
    "scripts/test-workstage-review-gate.sh",
    "scripts/workstage-review-gate-fixtures/green/advance_bootstrap/pr.json",
    "scripts/workstage-review-gate-fixtures/green/advance_repair/pr.json",
]


def write_fixture(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def pr_json(head_sha, base_sha=NORMAL_PARENT):
    return {
        "id": 123456789,
        "number": 2,
        "title": "MacsTeam Ultimate U1R18-R7-FIX1 NX Dispatch",
        "state": "OPEN",
        "draft": True,
        "merged": False,
        "mergeable": "MERGEABLE",
        "head": {
            "sha": head_sha,
            "ref": "feat/ultimate-cloverpit-u1",
            "repo": {"full_name": "oxcandy-lgtm/macsteam", "name": "macsteam"},
            "label": "oxcandy-lgtm:feat/ultimate-cloverpit-u1"
        },
        "base": {
            "sha": base_sha,
            "ref": "feat/public-oss-bootstrap",
            "repo": {"full_name": "oxcandy-lgtm/macsteam", "name": "macsteam"},
            "label": "oxcandy-lgtm:feat/public-oss-bootstrap"
        }
    }


def commit_json(sha, parents, date, message="fix: commit message"):
    return {
        "sha": sha,
        "parents": [{"sha": p} for p in parents],
        "commit": {
            "committer": {"date": date, "name": "Worker"},
            "author": {"date": date, "name": "Worker"},
            "message": message
        }
    }


def controller_review_json(commit_id, submitted_at, review_id,
                           classification=NORMAL_CLASSIFICATION,
                           decision="accepted",
                           review_complete=True,
                           nx_required=True,
                           ready=False, merge=False, release=False):
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
    return {
        "id": review_id,
        "user": {"login": "controller"},
        "commit_id": commit_id,
        "state": "APPROVED",
        "body": CONTROLLER_MARKER + "\n```json\n" + json.dumps(json_body, indent=2) + "\n```\n",
        "submitted_at": submitted_at
    }


def controller_review_commented_json(commit_id, submitted_at, review_id,
                                      classification=NORMAL_CLASSIFICATION,
                                      **kwargs):
    r = controller_review_json(commit_id, submitted_at, review_id, classification=classification, **kwargs)
    r["state"] = "COMMENTED"
    return r


def bootstrap_review_json(submitted_at=BOOTSTRAP_REVIEW_TS):
    return {
        "id": BOOTSTRAP_REVIEW_ID,
        "user": {"login": "controller"},
        "commit_id": BOOTSTRAP_HEAD,
        "state": "APPROVED",
        "body": "Bootstrap review for R3 closure. Classification: " + BOOTSTRAP_CLASSIFICATION,
        "submitted_at": submitted_at
    }


def repair_review_json(submitted_at=REPAIR_REVIEW_TS):
    body = (
        CONTROLLER_MARKER + "\n"
        "```json\n"
        + json.dumps({
            "schema_version": 1,
            "kind": "controller_review",
            "head_sha": R7_HEAD,
            "decision": "rejected",
            "classification": REPAIR_CLASSIFICATION,
            "review_complete": True,
            "nx_required_for_next_workstream": True,
            "ready_authorized": False,
            "merge_authorized": False,
            "release_authorized": False
        }, indent=2) + "\n```\n"
        "\nR7 repair authorization granted for U1R18-R7-FIX1. "
        "This RED review is authorized for one-time repair by a direct child commit "
        "with message: ci: close workstream review authority gate (U1R18-R7-FIX1)\n"
        "Workstream: U1R18-R7-FIX1\n"
    )
    return {
        "id": REPAIR_REVIEW_ID,
        "user": {"login": "sai"},
        "commit_id": R7_HEAD,
        "state": "COMMENTED",
        "body": body,
        "submitted_at": submitted_at
    }


def worker_report_json(head_sha, parent_sha, created_at=WORKER_REPORT_CREATED,
                       run_id=CI_RUN_ID, workstream=FIX1_WORKSTREAM):
    report = {
        "schema_version": 1,
        "kind": "worker_report",
        "workstream": workstream,
        "head_sha": head_sha,
        "parent_sha": parent_sha,
        "commit_count": 1,
        "core_ci_run_id": run_id,
        "core_ci_jobs": REQUIRED_JOBS,
        "gate_advance_run_id": GATE_ADVANCE_RUN_ID,
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
        "body": WORKER_MARKER + "\n```json\n" + json.dumps(report, indent=2) + "\n```\n",
        "created_at": created_at,
        "updated_at": created_at
    }


def historical_worker_report_json(head_sha, parent_sha, comment_id=5161887200):
    report = {
        "schema_version": 1,
        "kind": "worker_report",
        "workstream": "U1R18-R7",
        "head_sha": head_sha,
        "parent_sha": parent_sha,
        "commit_count": 1,
        "core_ci_run_id": 30790400999,
        "core_ci_jobs": REQUIRED_JOBS,
        "gate_advance_run_id": 30790400998,
        "gate_submission_run_id": 30790400997,
        "stop": True,
        "next_workstream_started": False,
        "ready_performed": False,
        "merge_performed": False,
        "release_performed": False
    }
    return {
        "id": comment_id,
        "user": {"login": "macsteam-dev"},
        "body": WORKER_MARKER + "\n```json\n" + json.dumps(report, indent=2) + "\n```\n",
        "created_at": "2026-08-02T12:00:00Z",
        "updated_at": "2026-08-02T12:00:00Z"
    }


def workflow_run_json(run_id, head_sha, name="CI", status="completed", conclusion="success"):
    return {
        "id": run_id,
        "head_sha": head_sha,
        "status": status,
        "conclusion": conclusion,
        "name": name,
        "created_at": "2026-08-03T02:50:00Z"
    }


def runs_with_gate(head_sha, ci_run_id=CI_RUN_ID):
    return workflow_runs_json([
        workflow_run_json(ci_run_id, head_sha, "CI"),
        workflow_run_json(GATE_ADVANCE_RUN_ID, head_sha, "Workstream Review Gate"),
    ])


def workflow_runs_json(runs):
    return {"workflow_runs": runs}


def workflow_job_json(name, run_id, conclusion="success"):
    return {
        "id": run_id * 100 + hash(name) % 1000,
        "name": name,
        "conclusion": conclusion,
        "status": "completed",
        "run_id": run_id
    }


def workflow_jobs_json(jobs):
    return {"jobs": jobs}


def files_json(filenames):
    return [{"filename": f} for f in filenames]


CONTROLLER_MARKER = "<!-- macsteam-controller-review:v1 -->"
WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"


# === Fixture builders ===

def create_advance_bootstrap():
    d = os.path.join(FIXTURE_DIR, "green", "advance_bootstrap")
    write_fixture(f"{d}/pr.json", pr_json(R7_HEAD, base_sha=BOOTSTRAP_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(R7_HEAD, [BOOTSTRAP_HEAD], HEAD_COMMIT_TS,
                              "ci: enforce workstream review wait gate (U1R18-R7)"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(BOOTSTRAP_HEAD, [WRONG_SHA], "2026-08-03T01:00:00Z",
                              "U1R18: Add R3 semantic mutation scanner"))
    write_fixture(f"{d}/reviews.json", [bootstrap_review_json()])
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", {"workflow_runs": []})
    write_fixture(f"{d}/jobs.json", {"jobs": []})
    print(f"  created {d}")


def create_advance_repair():
    d = os.path.join(FIXTURE_DIR, "green", "advance_repair")
    write_fixture(f"{d}/pr.json", pr_json(FIX1_HEAD, base_sha=R7_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(FIX1_HEAD, [R7_HEAD], HEAD_COMMIT_TS, REPAIR_COMMIT_MSG))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(R7_HEAD, [BOOTSTRAP_HEAD], BOOTSTRAP_REVIEW_TS))
    write_fixture(f"{d}/reviews.json", [repair_review_json()])
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", {"workflow_runs": []})
    write_fixture(f"{d}/jobs.json", {"jobs": []})
    write_fixture(f"{d}/files.json", files_json(ALLOWED_FILES))
    print(f"  created {d}")


def create_advance_normal_commented():
    d = os.path.join(FIXTURE_DIR, "green", "advance_normal_commented")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    write_fixture(f"{d}/reviews.json",
                  [controller_review_commented_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)])
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", {"workflow_runs": []})
    write_fixture(f"{d}/jobs.json", {"jobs": []})
    print(f"  created {d}")


def create_advance_normal_approved():
    d = os.path.join(FIXTURE_DIR, "green", "advance_normal_approved")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    write_fixture(f"{d}/reviews.json",
                  [controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)])
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", {"workflow_runs": []})
    write_fixture(f"{d}/jobs.json", {"jobs": []})
    print(f"  created {d}")


def create_submission_historical_reports():
    d = os.path.join(FIXTURE_DIR, "green", "submission_historical_reports")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    write_fixture(f"{d}/reviews.json",
                  [controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)])
    comments = [
        worker_report_json(NORMAL_HEAD, NORMAL_PARENT),
        historical_worker_report_json(HISTORICAL_HEAD, HISTORICAL_PARENT, 5161887200),
    ]
    write_fixture(f"{d}/comments.json", comments)
    write_fixture(f"{d}/runs.json", runs_with_gate(NORMAL_HEAD))
    write_fixture(f"{d}/jobs.json",
                  workflow_jobs_json([workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]))
    print(f"  created {d}")


def create_submission_historical_reviews():
    d = os.path.join(FIXTURE_DIR, "green", "submission_historical_reviews")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    reviews = [
        controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID),
        controller_review_json(HISTORICAL_HEAD, "2026-08-02T12:00:00Z", 4840817799,
                               classification="GREEN_U1R18_R7_REVIEWED"),
    ]
    write_fixture(f"{d}/reviews.json", reviews)
    write_fixture(f"{d}/comments.json", [worker_report_json(NORMAL_HEAD, NORMAL_PARENT)])
    write_fixture(f"{d}/runs.json", runs_with_gate(NORMAL_HEAD))
    write_fixture(f"{d}/jobs.json",
                  workflow_jobs_json([workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]))
    print(f"  created {d}")


def create_review_commented_accepted():
    d = os.path.join(FIXTURE_DIR, "green", "review_commented_accepted")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    reviews = [
        controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID),
        controller_review_commented_json(NORMAL_HEAD, HEAD_REVIEW_TS, HEAD_REVIEW_ID,
                                         classification="GREEN_U1R18_R7_REVIEW_ACCEPTED"),
    ]
    write_fixture(f"{d}/reviews.json", reviews)
    write_fixture(f"{d}/comments.json", [worker_report_json(NORMAL_HEAD, NORMAL_PARENT)])
    write_fixture(f"{d}/runs.json", runs_with_gate(NORMAL_HEAD))
    write_fixture(f"{d}/jobs.json",
                  workflow_jobs_json([workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]))
    print(f"  created {d}")


def create_review_approved_accepted():
    d = os.path.join(FIXTURE_DIR, "green", "review_approved_accepted")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    reviews = [
        controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID),
        controller_review_json(NORMAL_HEAD, HEAD_REVIEW_TS, HEAD_REVIEW_ID,
                               classification="GREEN_U1R18_R7_REVIEW_ACCEPTED"),
    ]
    write_fixture(f"{d}/reviews.json", reviews)
    write_fixture(f"{d}/comments.json", [worker_report_json(NORMAL_HEAD, NORMAL_PARENT)])
    write_fixture(f"{d}/runs.json", runs_with_gate(NORMAL_HEAD))
    write_fixture(f"{d}/jobs.json",
                  workflow_jobs_json([workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]))
    print(f"  created {d}")


def create_multi_page_comments():
    d = os.path.join(FIXTURE_DIR, "green", "multi_page_comments")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    write_fixture(f"{d}/reviews.json",
                  [controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)])
    comments = [worker_report_json(NORMAL_HEAD, NORMAL_PARENT)]
    for i in range(30):
        comments.append({
            "id": 6000000000 + i,
            "user": {"login": "macsteam-dev"},
            "body": f"Regular comment {i}",
            "created_at": f"2026-08-03T02:{i:02d}:00Z",
            "updated_at": f"2026-08-03T02:{i:02d}:00Z"
        })
    write_fixture(f"{d}/comments.json", comments)
    write_fixture(f"{d}/runs.json", runs_with_gate(NORMAL_HEAD))
    write_fixture(f"{d}/jobs.json",
                  workflow_jobs_json([workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]))
    print(f"  created {d}")


def create_multi_page_reviews():
    d = os.path.join(FIXTURE_DIR, "green", "multi_page_reviews")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    reviews = [controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)]
    for i in range(30):
        reviews.append({
            "id": 7000000000 + i,
            "user": {"login": "reviewer"},
            "commit_id": HISTORICAL_HEAD if i % 2 == 0 else NORMAL_HEAD,
            "state": "COMMENTED",
            "body": f"Note {i}",
            "submitted_at": f"2026-08-03T02:{i:02d}:00Z"
        })
    write_fixture(f"{d}/reviews.json", reviews)
    write_fixture(f"{d}/comments.json", [])
    write_fixture(f"{d}/runs.json", {"workflow_runs": []})
    write_fixture(f"{d}/jobs.json", {"jobs": []})
    print(f"  created {d}")


def create_multi_page_runs_jobs():
    d = os.path.join(FIXTURE_DIR, "green", "multi_page_runs_jobs")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    write_fixture(f"{d}/reviews.json",
                  [controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)])
    write_fixture(f"{d}/comments.json", [worker_report_json(NORMAL_HEAD, NORMAL_PARENT)])
    runs = [
        workflow_run_json(CI_RUN_ID, NORMAL_HEAD, "CI"),
        workflow_run_json(GATE_ADVANCE_RUN_ID, NORMAL_HEAD, "Workstream Review Gate"),
    ]
    for i in range(20):
        runs.append({
            "id": 4000000000 + i,
            "head_sha": NORMAL_HEAD,
            "status": "completed",
            "conclusion": "success",
            "name": "Other Workflow",
            "created_at": "2026-08-03T02:50:00Z"
        })
    write_fixture(f"{d}/runs.json", workflow_runs_json(runs))
    jobs = [workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]
    for i in range(10):
        jobs.append({
            "id": 5000000000 + i,
            "name": f"Extra Job {i}",
            "conclusion": "success",
            "status": "completed",
            "run_id": 4000000000
        })
    write_fixture(f"{d}/jobs.json", workflow_jobs_json(jobs))
    print(f"  created {d}")


def create_latest_accept_after_reject():
    d = os.path.join(FIXTURE_DIR, "green", "latest_accept_after_reject")
    write_fixture(f"{d}/pr.json", pr_json(NORMAL_HEAD))
    write_fixture(f"{d}/commit_HEAD.json",
                  commit_json(NORMAL_HEAD, [NORMAL_PARENT], HEAD_COMMIT_TS,
                              "feat: normal workstream commit"))
    write_fixture(f"{d}/commit_PARENT.json",
                  commit_json(NORMAL_PARENT, [WRONG_SHA], "2026-08-03T01:00:00Z"))
    # Parent review: normal accepted
    parent_review = controller_review_json(NORMAL_PARENT, PARENT_REVIEW_TS, NORMAL_REVIEW_ID)
    # HEAD review: older rejected, newer accepted
    rejected_review = {
        "id": 4840817800,
        "user": {"login": "controller"},
        "commit_id": NORMAL_HEAD,
        "state": "COMMENTED",
        "body": CONTROLLER_MARKER + "\n```json\n" + json.dumps({
            "schema_version": 1,
            "kind": "controller_review",
            "head_sha": NORMAL_HEAD,
            "decision": "rejected",
            "classification": "RED_U1R18_R7_SOME_REASON",
            "review_complete": True,
            "nx_required_for_next_workstream": True,
            "ready_authorized": False,
            "merge_authorized": False,
            "release_authorized": False
        }, indent=2) + "\n```\n",
        "submitted_at": REJECTED_REVIEW_TS
    }
    accepted_review = controller_review_json(NORMAL_HEAD, LATEST_ACCEPT_TS, LATEST_ACCEPT_REVIEW_ID,
                                             classification="GREEN_U1R18_R7_REVIEW_ACCEPTED")
    write_fixture(f"{d}/reviews.json", [parent_review, rejected_review, accepted_review])
    write_fixture(f"{d}/comments.json", [worker_report_json(NORMAL_HEAD, NORMAL_PARENT)])
    write_fixture(f"{d}/runs.json", runs_with_gate(NORMAL_HEAD))
    write_fixture(f"{d}/jobs.json",
                  workflow_jobs_json([workflow_job_json(j, CI_RUN_ID) for j in REQUIRED_JOBS]))
    print(f"  created {d}")


def main():
    print("Generating GREEN fixtures...")
    create_advance_bootstrap()
    create_advance_repair()
    create_advance_normal_commented()
    create_advance_normal_approved()
    create_submission_historical_reports()
    create_submission_historical_reviews()
    create_review_commented_accepted()
    create_review_approved_accepted()
    create_multi_page_comments()
    create_multi_page_reviews()
    create_multi_page_runs_jobs()
    create_latest_accept_after_reject()
    print("All GREEN fixtures created.")


if __name__ == "__main__":
    main()
