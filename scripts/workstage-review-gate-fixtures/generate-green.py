#!/usr/bin/env python3
"""Generate GREEN fixture bundles for workstage-review-gate — U1R18-R7-FIX2.

Creates all GREEN fixture directories that should pass the gate with exit code 0.

FIX2 notes:
  - Every normal-family parent controller review triggers §9 submission-receipt
    revalidation, so such fixtures carry a submission run anchored at the parent.
  - Submission-phase fixtures are routed through `_validate_parent_review`, so
    they MUST include a valid parent controller review (not just []).
  - Review-phase fixtures need BOTH a parent submission run (for §9 parent
    revalidation) and a head submission run (for `_validate_submission_receipt`).
"""

import json
import os
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(SCRIPT_DIR, "green")

# === SHA constants ===
BOOTSTRAP_HEAD = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"
R7_HEAD = "f3ae89d2caa07930ffda7a84059ecdfb18942e3d"
FIX1_HEAD = "4b7cbe162d0dbf4e660972b2eda3f369588884e3"
FIX2_HEAD = "b7c4f9a8c2d6e103547a9b8c0d2e3f4a5b6c7d8e"
NORMAL_PARENT = "6656ec33d15289ce122f4ba9d1e2db71f260d8b7"
NORMAL_HEAD = "0123456789abcdef0123456789abcdef01234567"
HISTORICAL_HEAD = "9999999999999999999999999999999999999999"
HISTORICAL_PARENT = "8888888888888888888888888888888888888888"
FUTURE_CHILD_HEAD = "c8d5f0ae1b2c3d4e5f6078901234567890abcdef"

FIX2_WORKSTREAM = "U1R18-R7-FIX2"
REPAIR_COMMIT_MSG = "ci: bind trusted submission receipt (U1R18-R7-FIX2)\n\nWorkstream: U1R18-R7-FIX2"

BOOTSTRAP_REVIEW_ID = 4840817794
REPAIR_REVIEW_ID = 4843792148
REPAIR_REVIEW_ID_CHILD = 4843792150
NORMAL_REVIEW_ID = 4840817795
HISTORICAL_REVIEW_ID = 4840817800
NORMAL_REVIEW_ID_CHILD = 4840817797

CI_RUN_ID = 30790400001
GATE_ADVANCE_RUN_ID = 30790400002
HEAD_SUBMISSION_RUN_ID = 30790400003
PARENT_SUBMISSION_RUN_ID = 30790400004
HISTORICAL_SUBMISSION_RUN_ID = 30790400005
FIX_SUBMISSION_RUN_ID = 30790400006

WORKER_REPORT_COMMENT_ID = 5161887211
WORKER_REPORT_COMMENT_ID_CHILD = 5161887212

REQUIRED_JOBS = ["Swift Build", "Public Audit", "Recipe Validation",
                 "License Validation", "Gitignore Validation"]

PARENT_REVIEW_TS = "2026-08-03T02:00:00Z"
BOOTSTRAP_REVIEW_TS = "2026-08-03T02:45:00Z"
REPAIR_REVIEW_TS = "2026-08-03T02:50:00Z"
HEAD_COMMIT_TS = "2026-08-03T03:00:00Z"
WORKER_REPORT_CREATED = "2026-08-03T03:10:00Z"
WORKER_REPORT_UPDATED = "2026-08-03T03:10:00Z"
HEAD_REVIEW_TS = "2026-08-03T03:15:00Z"
LATEST_ACCEPT_TS = "2026-08-03T03:20:00Z"
REJECTED_REVIEW_TS = "2026-08-03T03:15:00Z"
HEAD_SUB_STARTED = "2026-08-03T03:11:00Z"
HEAD_SUB_COMPLETED = "2026-08-03T03:12:00Z"
PARENT_SUB_STARTED = "2026-08-03T02:01:00Z"
PARENT_SUB_COMPLETED = "2026-08-03T02:02:00Z"

WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"
CONTROLLER_MARKER = "<!-- macsteam-controller-review:v1 -->"


def write_fixture(d, filename, data):
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, filename)
    with open(path, 'w') as f:
        if isinstance(data, str):
            f.write(data)
        else:
            json.dump(data, f, indent=2)


def pr_json(head_sha):
    return {
        "number": 2,
        "head": {"ref": "feat/ultimate-cloverpit-u1", "sha": head_sha,
                 "repo": {"full_name": "oxcandy-lgtm/macsteam"}},
        "base": {"ref": "feat/public-oss-bootstrap",
                 "repo": {"full_name": "oxcandy-lgtm/macsteam"}},
        "state": "open",
        "draft": True,
        "merged": False,
        "mergeable": "MERGEABLE",
        "title": "MacsTeam Ultimate U1R18-R7-FIX2 NX Dispatch",
        "html_url": "https://github.com/oxcandy-lgtm/macsteam/pull/2",
    }


def commit_json(head_sha, parent_sha, message=None):
    if message is None:
        message = "test commit\n"
    return {
        "sha": head_sha,
        "parents": [{"sha": parent_sha}],
        "commit": {
            "message": message,
            "committer": {"date": HEAD_COMMIT_TS, "name": "Test", "email": "test@example.com"},
            "author": {"date": HEAD_COMMIT_TS, "name": "Test", "email": "test@example.com"},
        },
    }


def worker_report_json(head_sha, parent_sha, comment_id=WORKER_REPORT_COMMENT_ID):
    report = {
        "schema_version": 1,
        "kind": "worker_report",
        "workstream": FIX2_WORKSTREAM,
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
        "release_performed": False
    }
    return {
        "id": comment_id,
        "user": {"login": "macsteam-dev"},
        "body": WORKER_MARKER + "\n```json\n" + json.dumps(report, indent=2) + "\n```\n",
        "created_at": WORKER_REPORT_CREATED,
        "updated_at": WORKER_REPORT_UPDATED,
        "path": None,
        "position": None,
        "in_reply_to_id": None,
    }


def digest(comment):
    return {k: comment[k] for k in ("id", "user", "body", "created_at",
                                    "updated_at", "path", "position", "in_reply_to_id")}


def submission_run_json(run_id, head_sha, report_comment_id, started, completed):
    return {
        "id": run_id,
        "name": f"MacSteam Workstage Review Gate / submission / PR=2 / HEAD={head_sha} / REPORT={report_comment_id}",
        "head_sha": head_sha,
        "head_branch": "feat/ultimate-cloverpit-u1",
        "workflow_id": 325971670,
        "workflow_path": ".github/workflows/workstage-review-gate.yml",
        "event": "workflow_dispatch",
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
        "run_started_at": started,
        "started_at": started,
        "created_at": started,
        "completed_at": completed,
        "html_url": f"https://github.com/oxcandy-lgtm/macsteam/actions/runs/{run_id}",
        "repository": {"full_name": "oxcandy-lgtm/macsteam"},
    }


def ci_run_json(run_id, head_sha, name="CI"):
    return {
        "id": run_id,
        "name": name,
        "head_sha": head_sha,
        "head_branch": "feat/ultimate-cloverpit-u1",
        "workflow_id": 320460394,
        "event": "push",
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
        "run_started_at": "2026-08-03T03:00:00Z",
        "started_at": "2026-08-03T03:00:00Z",
        "created_at": "2026-08-03T03:00:00Z",
        "completed_at": "2026-08-03T03:05:00Z",
        "html_url": f"https://github.com/oxcandy-lgtm/macsteam/actions/runs/{run_id}",
    }


def gate_advance_run_json(run_id, head_sha):
    return {
        "id": run_id,
        "name": "Workstream Review Gate",
        "head_sha": head_sha,
        "head_branch": "feat/ultimate-cloverpit-u1",
        "workflow_id": 325971670,
        "event": "workflow_dispatch",
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
        "run_started_at": "2026-08-03T03:06:00Z",
        "started_at": "2026-08-03T03:06:00Z",
        "created_at": "2026-08-03T03:06:00Z",
        "completed_at": "2026-08-03T03:08:00Z",
        "html_url": f"https://github.com/oxcandy-lgtm/macsteam/actions/runs/{run_id}",
    }


def controller_review_json(head_sha, wr_comment_id=WORKER_REPORT_COMMENT_ID,
                           sub_run_id=HEAD_SUBMISSION_RUN_ID, decision="accepted",
                           classification="GREEN_U1R18_R6_CONTROLLER_REVIEW_ACCEPTED"):
    inner = {
        "schema_version": 1,
        "kind": "controller_review",
        "head_sha": head_sha,
        "worker_report_comment_id": wr_comment_id,
        "submission_run_id": sub_run_id,
        "decision": decision,
        "classification": classification,
        "review_complete": True,
        "nx_required_for_next_workstream": True,
        "ready_authorized": False,
        "merge_authorized": False,
        "release_authorized": False,
    }
    return CONTROLLER_MARKER + "\n```json\n" + json.dumps(inner, indent=2) + "\n```\n"


def review_json(head_sha, review_id, body, state="APPROVED", ts=HEAD_REVIEW_TS):
    return {
        "id": review_id,
        "user": {"login": "sai-controller"},
        "commit_id": head_sha,
        "state": state,
        "body": body,
        "submitted_at": ts,
        "html_url": f"https://github.com/oxcandy-lgtm/macsteam/pull/2#pullrequestreview-{review_id}",
    }


def workflow_job_json(job_name, run_id):
    return {
        "id": run_id * 100 + (abs(hash(job_name)) % 10000),
        "name": job_name,
        "status": "completed",
        "conclusion": "success",
        "run_id": run_id,
        "html_url": f"https://github.com/oxcandy-lgtm/macsteam/runs/{run_id}",
    }


def jobs_json(required_jobs=REQUIRED_JOBS, run_id=CI_RUN_ID):
    return {"total_count": len(required_jobs), "jobs": [workflow_job_json(j, run_id) for j in required_jobs]}


def submission_jobs_json(run_id):
    return {"total_count": 1, "jobs": [workflow_job_json("Submission Gate", run_id)]}


def comments_json(*items):
    return list(items)


def _base(d, head_sha=NORMAL_HEAD, parent_sha=NORMAL_PARENT, message=None):
    write_fixture(d, "pr.json", pr_json(head_sha))
    write_fixture(d, "commit_HEAD.json", commit_json(head_sha, parent_sha, message))
    write_fixture(d, "commit_PARENT.json", commit_json(parent_sha, HISTORICAL_PARENT))
    write_fixture(d, "comments.json", comments_json())


def _parent_receipt(d, parent_head=NORMAL_PARENT):
    """Parent-anchored submission run needed for §9 revalidation."""
    write_fixture(d, "submission-runs.json", {"total_count": 1, "workflow_runs": [
        submission_run_json(PARENT_SUBMISSION_RUN_ID, parent_head, WORKER_REPORT_COMMENT_ID,
                            PARENT_SUB_STARTED, PARENT_SUB_COMPLETED)
    ]})
    write_fixture(d, "submission-jobs.json", submission_jobs_json(PARENT_SUBMISSION_RUN_ID))


def _head_and_parent_receipts(d, head_head=NORMAL_HEAD, parent_head=NORMAL_PARENT):
    write_fixture(d, "submission-runs.json", {"total_count": 2, "workflow_runs": [
        submission_run_json(PARENT_SUBMISSION_RUN_ID, parent_head, WORKER_REPORT_COMMENT_ID,
                            PARENT_SUB_STARTED, PARENT_SUB_COMPLETED),
        submission_run_json(HEAD_SUBMISSION_RUN_ID, head_head, WORKER_REPORT_COMMENT_ID,
                            HEAD_SUB_STARTED, HEAD_SUB_COMPLETED),
    ]})
    write_fixture(d, "submission-jobs.json", {
        "total_count": 2,
        "jobs": [workflow_job_json("Submission Gate", PARENT_SUBMISSION_RUN_ID),
                 workflow_job_json("Submission Gate", HEAD_SUBMISSION_RUN_ID)],
    })


def _ci_files(d, head=NORMAL_HEAD):
    write_fixture(d, "runs.json", {"total_count": 2, "workflow_runs": [
        ci_run_json(CI_RUN_ID, head),
        gate_advance_run_json(GATE_ADVANCE_RUN_ID, head),
    ]})
    write_fixture(d, "jobs.json", jobs_json())


# === Advance phase ===

def create_advance_normal_approved():
    d = os.path.join(FIXTURE_DIR, "advance_normal_approved")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, body, "APPROVED", PARENT_REVIEW_TS)])
    _parent_receipt(d)


def create_advance_normal_commented():
    d = os.path.join(FIXTURE_DIR, "advance_normal_commented")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, body, "COMMENTED", PARENT_REVIEW_TS)])
    _parent_receipt(d)


def create_advance_bootstrap():
    d = os.path.join(FIXTURE_DIR, "advance_bootstrap")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d, head_sha=R7_HEAD, parent_sha=BOOTSTRAP_HEAD)
    body = ("Bootstrap review authorizing closure of R3. "
            "Classification: GREEN_U1R18_R3_OWNERSHIP_BOUND_REAL_WINDOW_DETECTION_CLOSED")
    write_fixture(d, "reviews.json",
                  [review_json(BOOTSTRAP_HEAD, BOOTSTRAP_REVIEW_ID, body, "APPROVED", BOOTSTRAP_REVIEW_TS)])
    write_fixture(d, "files.json", {"total_count": 0, "files": []})


def create_advance_repair():
    d = os.path.join(FIXTURE_DIR, "advance_repair")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d, head_sha=FIX2_HEAD, parent_sha=FIX1_HEAD, message=REPAIR_COMMIT_MSG)
    repair_body = (controller_review_json(FIX1_HEAD, decision="rejected",
                                          classification="RED_U1R18_R7_FIX1_CANONICAL_SUBMISSION_RECEIPT_NOT_BOUND")
                   + "\n\nR7 repair authorization granted for U1R18-R7-FIX2. "
                     "This RED review authorizes a single direct child commit.\n")
    write_fixture(d, "reviews.json",
                  [review_json(FIX1_HEAD, REPAIR_REVIEW_ID, repair_body, "APPROVED", REPAIR_REVIEW_TS)])
    write_fixture(d, "files.json", {"total_count": 0, "files": []})


def create_multi_page_reviews():
    d = os.path.join(FIXTURE_DIR, "multi_page_reviews")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    filler = []
    for i in range(6):
        filler.append({
            "id": 7000000000 + i,
            "user": {"login": "reviewer"},
            "commit_id": HISTORICAL_HEAD if i % 2 == 0 else NORMAL_PARENT,
            "state": "COMMENTED",
            "body": f"Note {i}",
            "submitted_at": PARENT_REVIEW_TS,
        })
    reviews = [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, body, "APPROVED", PARENT_REVIEW_TS)] + filler
    write_fixture(d, "reviews.json", reviews)
    write_fixture(d, "files.json", {"total_count": 0, "files": []})
    _parent_receipt(d)


def create_future_child_advance_revalidates_parent_receipt():
    d = os.path.join(FIXTURE_DIR, "future_child_advance_revalidates_parent_receipt")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d, head_sha=FUTURE_CHILD_HEAD, parent_sha=FIX2_HEAD,
          message="ci: next workstream\n\nWorkstream: U1R18-R9")
    write_fixture(d, "commit_PARENT.json", commit_json(FIX2_HEAD, FIX1_HEAD))
    body = controller_review_json(FIX2_HEAD, sub_run_id=FIX_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(FIX2_HEAD, REPAIR_REVIEW_ID_CHILD, body, "APPROVED", PARENT_REVIEW_TS)])
    write_fixture(d, "submission-runs.json", {"total_count": 1, "workflow_runs": [
        submission_run_json(FIX_SUBMISSION_RUN_ID, FIX2_HEAD, WORKER_REPORT_COMMENT_ID,
                            PARENT_SUB_STARTED, PARENT_SUB_COMPLETED)
    ]})
    write_fixture(d, "submission-jobs.json", submission_jobs_json(FIX_SUBMISSION_RUN_ID))


def create_latest_accept_after_reject():
    d = os.path.join(FIXTURE_DIR, "latest_accept_after_reject")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    reject_body = controller_review_json(NORMAL_HEAD, decision="rejected",
                                         classification="RED_U1R18_R7_SUBMISSION_RECEIPT_FAILURE")
    accept_body = controller_review_json(NORMAL_HEAD, sub_run_id=HEAD_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json", [
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_HEAD, 4840817798, reject_body, "APPROVED", REJECTED_REVIEW_TS),
        review_json(NORMAL_HEAD, NORMAL_REVIEW_ID_CHILD, accept_body, "APPROVED", LATEST_ACCEPT_TS),
    ])
    _ci_files(d)
    _head_and_parent_receipts(d)


# === Submission phase ===

def create_submission_historical_reports():
    d = os.path.join(FIXTURE_DIR, "submission_historical_reports")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    hist_wr = worker_report_json(HISTORICAL_HEAD, HISTORICAL_PARENT,
                                 comment_id=WORKER_REPORT_COMMENT_ID - 1)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(hist_wr), digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


def create_submission_historical_reviews():
    d = os.path.join(FIXTURE_DIR, "submission_historical_reviews")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    hist_body = controller_review_json(HISTORICAL_PARENT, wr_comment_id=WORKER_REPORT_COMMENT_ID - 1,
                                       sub_run_id=HISTORICAL_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json", [
        review_json(HISTORICAL_PARENT, HISTORICAL_REVIEW_ID, hist_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
    ])
    _ci_files(d)
    _parent_receipt(d)


def create_submission_exact_comment_id():
    d = os.path.join(FIXTURE_DIR, "submission_exact_comment_id")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


def create_submission_pre_report_null():
    d = os.path.join(FIXTURE_DIR, "submission_pre_report_null")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


def create_submission_trusted_github_run_id():
    d = os.path.join(FIXTURE_DIR, "submission_trusted_github_run_id")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


def create_multi_page_comments():
    d = os.path.join(FIXTURE_DIR, "multi_page_comments")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    filler = [{
        "id": 100 + i, "user": {"login": "x"}, "body": f"other {i}",
        "created_at": "2026-08-03T01:00:00Z", "updated_at": "2026-08-03T01:00:00Z",
        "path": None, "position": None, "in_reply_to_id": None,
    } for i in range(4)]
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(*filler, digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


def create_multi_page_runs_jobs():
    d = os.path.join(FIXTURE_DIR, "multi_page_runs_jobs")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


def create_historical_reports_plus_one_current():
    d = os.path.join(FIXTURE_DIR, "historical_reports_plus_one_current")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    hist_wr1 = worker_report_json(HISTORICAL_HEAD, HISTORICAL_PARENT,
                                  comment_id=WORKER_REPORT_COMMENT_ID - 1)
    hist_wr2 = worker_report_json(HISTORICAL_PARENT, WRONG_SHA,
                                  comment_id=WORKER_REPORT_COMMENT_ID - 2)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(hist_wr1), digest(hist_wr2), digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json",
                  [review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS)])
    _ci_files(d)
    _parent_receipt(d)


# === Review phase ===

def create_review_approved_accepted():
    d = os.path.join(FIXTURE_DIR, "review_approved_accepted")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    head_body = controller_review_json(NORMAL_HEAD, sub_run_id=HEAD_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json", [
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_HEAD, NORMAL_REVIEW_ID_CHILD, head_body, "APPROVED", HEAD_REVIEW_TS),
    ])
    _ci_files(d)
    _head_and_parent_receipts(d)


def create_review_commented_accepted():
    d = os.path.join(FIXTURE_DIR, "review_commented_accepted")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    head_body = controller_review_json(NORMAL_HEAD, sub_run_id=HEAD_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json", [
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_HEAD, NORMAL_REVIEW_ID_CHILD, head_body, "COMMENTED", HEAD_REVIEW_TS),
    ])
    _ci_files(d)
    _head_and_parent_receipts(d)


def create_review_commented_accepted_with_receipt():
    d = os.path.join(FIXTURE_DIR, "review_commented_accepted_with_receipt")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    head_body = controller_review_json(NORMAL_HEAD, sub_run_id=HEAD_SUBMISSION_RUN_ID,
                                       classification="GREEN_U1R18_R7_FIX2_SUBMISSION_RECEIPT_BOUND")
    write_fixture(d, "reviews.json", [
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_HEAD, NORMAL_REVIEW_ID_CHILD, head_body, "COMMENTED", HEAD_REVIEW_TS),
    ])
    _ci_files(d)
    _head_and_parent_receipts(d)


def create_review_exact_submission_receipt():
    d = os.path.join(FIXTURE_DIR, "review_exact_submission_receipt")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    head_body = controller_review_json(NORMAL_HEAD, sub_run_id=HEAD_SUBMISSION_RUN_ID,
                                       classification="GREEN_U1R18_R7_FIX2_SUBMISSION_RECEIPT_BOUND")
    write_fixture(d, "reviews.json", [
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_HEAD, NORMAL_REVIEW_ID_CHILD, head_body, "APPROVED", HEAD_REVIEW_TS),
    ])
    _ci_files(d)
    _head_and_parent_receipts(d)


def create_historical_submission_runs_do_not_collide():
    d = os.path.join(FIXTURE_DIR, "historical_submission_runs_do_not_collide")
    if os.path.exists(d):
        shutil.rmtree(d)
    _base(d)
    wr = worker_report_json(NORMAL_HEAD, NORMAL_PARENT)
    write_fixture(d, "comment.json", digest(wr))
    write_fixture(d, "comments.json", comments_json(digest(wr)))
    parent_body = controller_review_json(NORMAL_PARENT, sub_run_id=PARENT_SUBMISSION_RUN_ID)
    head_body = controller_review_json(NORMAL_HEAD, sub_run_id=HEAD_SUBMISSION_RUN_ID)
    write_fixture(d, "reviews.json", [
        review_json(NORMAL_PARENT, NORMAL_REVIEW_ID, parent_body, "APPROVED", PARENT_REVIEW_TS),
        review_json(NORMAL_HEAD, NORMAL_REVIEW_ID_CHILD, head_body, "APPROVED", HEAD_REVIEW_TS),
    ])
    _ci_files(d)
    # Parent + head receipt runs PLUS a historical submission run for another HEAD
    write_fixture(d, "submission-runs.json", {"total_count": 3, "workflow_runs": [
        submission_run_json(PARENT_SUBMISSION_RUN_ID, NORMAL_PARENT, WORKER_REPORT_COMMENT_ID,
                            PARENT_SUB_STARTED, PARENT_SUB_COMPLETED),
        submission_run_json(HEAD_SUBMISSION_RUN_ID, NORMAL_HEAD, WORKER_REPORT_COMMENT_ID,
                            HEAD_SUB_STARTED, HEAD_SUB_COMPLETED),
        submission_run_json(HISTORICAL_SUBMISSION_RUN_ID, HISTORICAL_HEAD, WORKER_REPORT_COMMENT_ID - 1,
                            PARENT_SUB_STARTED, PARENT_SUB_COMPLETED),
    ]})
    write_fixture(d, "submission-jobs.json", {
        "total_count": 3,
        "jobs": [workflow_job_json("Submission Gate", PARENT_SUBMISSION_RUN_ID),
                 workflow_job_json("Submission Gate", HEAD_SUBMISSION_RUN_ID),
                 workflow_job_json("Submission Gate", HISTORICAL_SUBMISSION_RUN_ID)],
    })


GREEN_FACTORIES = [
    create_advance_bootstrap,
    create_advance_normal_approved,
    create_advance_normal_commented,
    create_advance_repair,
    create_latest_accept_after_reject,
    create_multi_page_reviews,
    create_multi_page_comments,
    create_multi_page_runs_jobs,
    create_submission_pre_report_null,
    create_submission_exact_comment_id,
    create_submission_trusted_github_run_id,
    create_review_exact_submission_receipt,
    create_review_commented_accepted_with_receipt,
    create_future_child_advance_revalidates_parent_receipt,
    create_historical_reports_plus_one_current,
    create_historical_submission_runs_do_not_collide,
    create_submission_historical_reports,
    create_submission_historical_reviews,
    create_review_approved_accepted,
    create_review_commented_accepted,
]

WRONG_SHA = "cafe1234cafe1234cafe1234cafe1234cafe1234"


if __name__ == "__main__":
    for factory in GREEN_FACTORIES:
        factory()
        print(f"Created: {factory.__name__}")
    print(f"\nTotal GREEN fixtures: {len(GREEN_FACTORIES)}")
