#!/usr/bin/env python3
"""
Mutation applier for workshift-review-gate fixture testing.

Usage:
  python3 apply-mutation.py M1 /path/to/temp/dir

Each mutation modifies fixture JSON files in the temp directory to simulate
a specific policy/protocol violation.
"""

import json
import os
import re
import sys

HEAD_NORMAL = "dad91d9ea3a6338b795f1472d0e4f729a1e419db"
WRONG_SHA = "cafe1234cafe1234cafe1234cafe1234cafe1234"
BOOTSTRAP_REVIEW_ID = 4840817794
REVIEW_BEFORE_TS = "2026-08-03T02:51:00Z"
REPORT_CREATED_TS = "2026-08-03T02:53:00Z"

WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"


def load_json(temp_dir, filename):
    path = os.path.join(temp_dir, filename)
    with open(path) as f:
        return json.load(f)


def save_json(temp_dir, filename, data):
    path = os.path.join(temp_dir, filename)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def m1_parent_review_removed(d):
    """Remove all reviews."""
    save_json(d, "reviews.json", [])


def m2_review_commit_id_wrong(d):
    """Change review commit_id to wrong value."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        r["commit_id"] = WRONG_SHA
    save_json(d, "reviews.json", reviews)


def m3_worker_report_removed(d):
    """Remove Worker report comments."""
    save_json(d, "comments.json", [])


def m4_stop_flag_false(d):
    """Set stop=false in Worker report JSON."""
    comments = load_json(d, "comments.json")
    for c in comments:
        body = c.get("body", "")
        if WORKER_MARKER not in body:
            continue
        idx = body.find(WORKER_MARKER)
        rest = body[idx:]
        m = re.search(r'```json\s*\n(.*?)\n```', rest, re.DOTALL)
        if m:
            j = json.loads(m.group(1))
            j["stop"] = False
            new_block = "```json\n" + json.dumps(j, indent=2) + "\n```"
            body = body[:idx + len(WORKER_MARKER)] + body[idx + len(WORKER_MARKER):].replace(m.group(0), new_block, 1)
            c["body"] = body
    save_json(d, "comments.json", comments)


def m5_merge_commit(d):
    """Add second parent to HEAD commit."""
    commit = load_json(d, "commit_HEAD.json")
    commit["parents"].append({"sha": "0000000000000000000000000000000000000002"})
    save_json(d, "commit_HEAD.json", commit)


def m6_ci_run_wrong_head(d):
    """Change CI run head_sha."""
    runs = load_json(d, "runs.json")
    for run in runs.get("workflow_runs", []):
        run["head_sha"] = WRONG_SHA
    save_json(d, "runs.json", runs)


def m7_job_failed(d):
    """Set first job conclusion to failure."""
    jobs = load_json(d, "jobs.json")
    if jobs.get("jobs"):
        jobs["jobs"][0]["conclusion"] = "failure"
    save_json(d, "jobs.json", jobs)


def m8_review_before_report(d):
    """Set HEAD review submitted_at to before Worker report."""
    reviews = load_json(d, "reviews.json")
    for r in reviews:
        if r.get("commit_id") == HEAD_NORMAL:
            r["submitted_at"] = REVIEW_BEFORE_TS
    save_json(d, "reviews.json", reviews)


def m9_newer_red_review(d):
    """Add a CHANGES_REQUESTED review after the accepted review."""
    reviews = load_json(d, "reviews.json")
    reviews.append({
        "id": 4840817799,
        "user": {"login": "controller"},
        "commit_id": HEAD_NORMAL,
        "state": "CHANGES_REQUESTED",
        "body": "Requesting changes — new issues found",
        "submitted_at": "2026-08-03T02:58:00Z"
    })
    save_json(d, "reviews.json", reviews)


def m10_bootstrap_review_removed(d):
    """Remove bootstrap review (by ID) from reviews."""
    reviews = load_json(d, "reviews.json")
    reviews = [r for r in reviews if r.get("id") != BOOTSTRAP_REVIEW_ID]
    save_json(d, "reviews.json", reviews)


def m11_draft_false(d):
    """Set PR draft to false."""
    pr = load_json(d, "pr.json")
    pr["draft"] = False
    save_json(d, "pr.json", pr)


def m12_api_data_removed(d):
    """Remove reviews.json (simulating API failure)."""
    path = os.path.join(d, "reviews.json")
    if os.path.exists(path):
        os.remove(path)


MUTATIONS = {
    "M1": ("M1_parent_review_removed", m1_parent_review_removed),
    "M2": ("M2_review_commit_id_wrong", m2_review_commit_id_wrong),
    "M3": ("M3_worker_report_removed", m3_worker_report_removed),
    "M4": ("M4_stop_flag_false", m4_stop_flag_false),
    "M5": ("M5_merge_commit", m5_merge_commit),
    "M6": ("M6_ci_run_wrong_head", m6_ci_run_wrong_head),
    "M7": ("M7_job_failed", m7_job_failed),
    "M8": ("M8_review_before_report", m8_review_before_report),
    "M9": ("M9_newer_red_review", m9_newer_red_review),
    "M10": ("M10_bootstrap_review_removed", m10_bootstrap_review_removed),
    "M11": ("M11_draft_false", m11_draft_false),
    "M12": ("M12_api_data_removed", m12_api_data_removed),
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

    label, func = MUTATIONS[mut_name]
    func(temp_dir)
    print(f"Applied {label}")


if __name__ == "__main__":
    main()
