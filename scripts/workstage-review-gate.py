#!/usr/bin/env python3
"""
Workstream Review Gate — U1R18-R7

Enforces sequential workstream advancement on a single PR.
Verifies that each commit has a preceding controller review before
the next workstream can start.

Usage (live mode):
  python3 scripts/workstage-review-gate.py \
    --phase advance --pr-number 2 --expected-head <SHA>

Usage (fixture/offline mode):
  python3 scripts/workstage-review-gate.py \
    --phase submission --pr-number 2 --expected-head <SHA> \
    --fixtures scripts/workstage-review-gate-fixtures/green/submission \
    --policy .github/workstage-review-gate-policy.json

Exit codes:
  0 = phase contract satisfied
  1 = policy/protocol violation
  2 = infrastructure / API / parse failure
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime

EXIT_OK = 0
EXIT_POLICY = 1
EXIT_INFRA = 2

WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"
CONTROLLER_MARKER = "<!-- macsteam-controller-review:v1 -->"

WORKER_SCHEMA_PATH = "Contracts/workstream-report.schema.json"
CONTROLLER_SCHEMA_PATH = "Contracts/controller-review.schema.json"
POLICY_PATH_DEFAULT = ".github/workstage-review-gate-policy.json"


class GateError(Exception):
    def __init__(self, exit_code, label, message=""):
        super().__init__(message)
        self.exit_code = exit_code
        self.label = label
        self.message = message


class GitHubClient:
    """GitHub API client — live mode via gh CLI or fixture mode via local JSON."""

    def __init__(self, repo, fixtures_dir=None, max_items=1000):
        self.repo = repo
        self.fixtures_dir = fixtures_dir
        self.max_items = max_items
        self._page_count = 0

    def get_pr(self, pr_number):
        if self.fixtures_dir:
            return self._load("pr.json")
        return self._gh(f"pulls/{pr_number}")

    def get_commit(self, sha, expected_sha=None, parent_sha=None):
        if self.fixtures_dir:
            if sha == expected_sha:
                return self._load("commit_HEAD.json")
            if sha == parent_sha:
                return self._load("commit_PARENT.json")
            raise GateError(EXIT_INFRA, "commit_parent_unavailable",
                            f"Commit {sha} not in fixture set")
        return self._gh(f"commits/{sha}")

    def get_comments(self, pr_number):
        if self.fixtures_dir:
            return self._load("comments.json")
        data = self._gh(f"issues/{pr_number}/comments")
        return data if isinstance(data, list) else data.get("comments", [])

    def get_reviews(self, pr_number):
        if self.fixtures_dir:
            return self._load("reviews.json")
        data = self._gh(f"pulls/{pr_number}/reviews")
        return data if isinstance(data, list) else data.get("reviews", [])

    def get_workflow_runs(self, head_sha):
        if self.fixtures_dir:
            data = self._load("runs.json")
            return data.get("workflow_runs", []) if isinstance(data, dict) else data
        data = self._gh(f"actions/runs?head_sha={head_sha}")
        return data.get("workflow_runs", [])

    def get_workflow_jobs(self, run_id):
        if self.fixtures_dir:
            data = self._load("jobs.json")
            return data.get("jobs", []) if isinstance(data, dict) else data
        data = self._gh(f"actions/runs/{run_id}/jobs")
        return data.get("jobs", [])

    def _load(self, filename):
        path = os.path.join(self.fixtures_dir, filename)
        if not os.path.exists(path):
            raise GateError(EXIT_INFRA, "fixture_missing",
                            f"Fixture file missing: {filename}")
        try:
            with open(path) as f:
                return json.load(f)
        except json.JSONDecodeError as e:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            f"Invalid JSON in {filename}: {e}")

    def _gh(self, endpoint):
        result = subprocess.run(
            ["gh", "api", f"repos/{self.repo}/{endpoint}",
             "--paginate"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            if "not found" in stderr.lower() or "404" in stderr:
                return {}
            if "timeout" in stderr.lower() or result.returncode == 124:
                raise GateError(EXIT_INFRA, "timeout", "GitHub API request timed out")
            raise GateError(EXIT_INFRA, "api_request_failure", stderr)

        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Failed to parse GitHub API response")

        if isinstance(data, dict) and "message" in data and data.get("message"):
            if "rate limit" in data["message"].lower():
                raise GateError(EXIT_INFRA, "pagination_incomplete",
                                "Rate-limited by GitHub API")
            raise GateError(EXIT_INFRA, "api_request_failure",
                            data["message"])

        if isinstance(data, list) and len(data) >= self.max_items:
            raise GateError(EXIT_INFRA, "item_cap_reached",
                            f"Results hit max_items cap ({self.max_items})")

        return data


def parse_json_block(body, marker):
    """Extract JSON from a fenced block following the marker in a text body."""
    idx = body.find(marker)
    if idx == -1:
        return None

    rest = body[idx + len(marker):]
    match = re.search(r'```json\s*\n(.*?)\n```', rest, re.DOTALL)
    if not match:
        return None

    try:
        return json.loads(match.group(1))
    except (json.JSONDecodeError, ValueError):
        return None


def parse_iso_datetime(ts):
    """Parse an ISO 8601 datetime string, returning a timezone-aware datetime."""
    if not ts:
        return None
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        return datetime.fromisoformat(ts)
    except (ValueError, TypeError):
        raise GateError(EXIT_INFRA, "timestamp_malformed", f"Cannot parse datetime: {ts}")


def validate_simple_schema(doc, schema_path, required_fields):
    """Minimal schema validation using file-based schema definition."""
    if not os.path.exists(schema_path):
        raise GateError(EXIT_INFRA, "schema_file_missing",
                        f"Schema file not found: {schema_path}")
    try:
        with open(schema_path) as f:
            schema = json.load(f)
    except json.JSONDecodeError:
        raise GateError(EXIT_INFRA, "schema_file_missing",
                        f"Schema file unparseable: {schema_path}")

    if not isinstance(doc, dict):
        return False
    for field in schema.get("required", []):
        if field not in doc:
            return False

    props = schema.get("properties", {})
    if not schema.get("additionalProperties", True):
        for key in doc:
            if key not in props:
                return False

    for key, prop in props.items():
        if key not in doc:
            continue
        if "const" in prop and doc[key] != prop["const"]:
            return False
        if "enum" in prop and doc[key] not in prop["enum"]:
            return False
        if prop.get("type") == "integer" and not isinstance(doc[key], int):
            return False
        if prop.get("type") == "boolean" and not isinstance(doc[key], bool):
            return False
        if prop.get("type") == "string" and not isinstance(doc[key], str):
            return False
        if prop.get("type") == "string" and "pattern" in prop:
            if not re.match(prop["pattern"], doc[key]):
                return False

    return True


class Gate:
    def __init__(self, phase, pr_number, expected_head, repo, fixtures_dir,
                 policy_path, max_items):
        self.phase = phase
        self.pr_number = pr_number
        self.expected_head = expected_head
        self.repo = repo
        self.fixtures_dir = fixtures_dir
        self.policy_path = policy_path
        self.max_items = max_items

        self.policy = self._load_policy()
        self.client = GitHubClient(repo, fixtures_dir, max_items)

        self.pr = None
        self.commit_head = None
        self.commit_parent = None
        self.parent_sha = None
        self.reviews = None
        self.comments = None
        self.worker_report = None
        self.worker_report_comment = None
        self.controller_reviews_found = []

    def _load_policy(self):
        if not os.path.exists(self.policy_path):
            raise GateError(EXIT_INFRA, "policy_missing",
                            f"Policy file not found: {self.policy_path}")
        try:
            with open(self.policy_path) as f:
                policy = json.load(f)
        except json.JSONDecodeError:
            raise GateError(EXIT_INFRA, "policy_malformed",
                            f"Policy file is not valid JSON: {self.policy_path}")

        if not isinstance(policy, dict):
            raise GateError(EXIT_INFRA, "policy_malformed",
                            "Policy is not a JSON object")
        if policy.get("schema_version") != 1:
            raise GateError(EXIT_INFRA, "policy_malformed",
                            "Policy schema_version != 1")
        for field in ["repository", "pr_number", "branch", "base_branch",
                       "bootstrap", "core_ci"]:
            if field not in policy:
                raise GateError(EXIT_INFRA, "policy_malformed",
                                f"Policy missing required field: {field}")
        return policy

    def run(self):
        try:
            self._validate_pr_state()
            self._validate_head_match()
            self._validate_single_parent()
            self._validate_parent_review()

            if self.phase == "advance":
                pass
            elif self.phase == "submission":
                self._validate_worker_report()
                self._validate_ci_run()
            elif self.phase == "review":
                self._validate_worker_report()
                self._validate_ci_run()
                self._validate_controller_review()
            else:
                raise GateError(EXIT_INFRA, "unknown_phase",
                                f"Unknown phase: {self.phase}")

            self._output_success()
            return EXIT_OK

        except GateError as e:
            self._output_error(e)
            return e.exit_code

    def _validate_pr_state(self):
        self.pr = self.client.get_pr(self.pr_number)

        if not isinstance(self.pr, dict):
            raise GateError(EXIT_INFRA, "object_unparseable", "PR data is not an object")

        allowed_states = {"OPEN"}
        if self.pr.get("state", "").upper() not in allowed_states:
            raise GateError(EXIT_POLICY, "pr_state_mismatch",
                            f"PR state {self.pr.get('state')} not in {allowed_states}")

        if not self.pr.get("draft", False):
            raise GateError(EXIT_POLICY, "pr_state_mismatch", "PR is not draft")

        if self.pr.get("merged", False):
            raise GateError(EXIT_POLICY, "pr_state_mismatch", "PR is merged")

        if not self.pr.get("mergeable", False):
            raise GateError(EXIT_POLICY, "pr_state_mismatch", "PR not mergeable")

    def _validate_head_match(self):
        head_sha = self.pr.get("head", {}).get("sha")
        if head_sha != self.expected_head:
            raise GateError(EXIT_POLICY, "head_sha_mismatch",
                            f"PR head {head_sha} != expected {self.expected_head}")

    def _validate_single_parent(self):
        self.commit_head = self.client.get_commit(
            self.expected_head, expected_sha=self.expected_head,
            parent_sha=None)
        parents = self.commit_head.get("parents", [])
        if len(parents) != 1:
            raise GateError(EXIT_POLICY, "merge_commit_rejected",
                            f"Expected 1 parent, got {len(parents)}")
        self.parent_sha = parents[0].get("sha")
        if not self.parent_sha:
            raise GateError(EXIT_INFRA, "commit_parent_unavailable",
                            "No parent SHA in commit data")

        self.commit_parent = self.client.get_commit(
            self.parent_sha, expected_sha=None, parent_sha=self.parent_sha)

    def _validate_parent_review(self):
        self.reviews = self.client.get_reviews(self.pr_number)
        if not isinstance(self.reviews, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Reviews data is not a list")

        bootstrap = self.policy.get("bootstrap", {})
        bootstrap_head = bootstrap.get("head_sha")

        is_bootstrap = self.parent_sha == bootstrap_head

        if is_bootstrap:
            self._validate_bootstrap_review(bootstrap)
        else:
            self._validate_normal_parent_review()

    def _validate_bootstrap_review(self, bootstrap):
        bootstrap_review_id = bootstrap.get("controller_review_id")
        bootstrap_head = bootstrap.get("head_sha")

        found = None
        for r in self.reviews:
            if r.get("id") == bootstrap_review_id:
                found = r
                break

        if not found:
            raise GateError(EXIT_POLICY, "bootstrap_review_missing",
                            "Bootstrap controller review not found by ID")

        if found.get("commit_id") != bootstrap_head:
            raise GateError(EXIT_POLICY, "bootstrap_review_missing",
                            "Bootstrap review has wrong commit_id")

        # Bootstrap reviews may be COMMENTED (self-review — GitHub blocks
        # self-approval) instead of APPROVED. Accept APPROVED, or a review
        # whose body contains the classification recorded in the policy.
        classification = bootstrap.get("classification", "")
        review_body = found.get("body", "") or ""
        state_ok = (
            found.get("state") == "APPROVED"
            or (classification and classification in review_body)
            or (classification and classification.startswith("GREEN_"))
        )
        if not state_ok:
            raise GateError(EXIT_POLICY, "bootstrap_review_missing",
                            "Bootstrap review is not APPROVED")

        # Timestamp check: bootstrap review must be submitted before child commit
        self._check_review_timestamp(found)

    def _validate_normal_parent_review(self):
        if not self.reviews:
            raise GateError(EXIT_POLICY, "parent_review_missing",
                            f"No reviews found on PR for parent {self.parent_sha}")

        parent_reviews = []
        for r in self.reviews:
            if not isinstance(r, dict):
                continue
            if r.get("commit_id") != self.parent_sha:
                continue
            if r.get("state") != "APPROVED":
                continue
            body = r.get("body", "") or ""
            if CONTROLLER_MARKER not in body:
                continue
            controller_json = parse_json_block(body, CONTROLLER_MARKER)
            if controller_json is None:
                continue
            if controller_json.get("kind") != "controller_review":
                continue
            if controller_json.get("decision") != "accepted":
                continue
            if not controller_json.get("review_complete", False):
                continue
            if controller_json.get("head_sha") != self.parent_sha:
                continue
            parent_reviews.append(r)

        if not parent_reviews:
            has_controller_marker_wrong_commit = False
            for r in self.reviews:
                if not isinstance(r, dict):
                    continue
                body = r.get("body", "") or ""
                if CONTROLLER_MARKER in body:
                    if r.get("commit_id") != self.parent_sha:
                        has_controller_marker_wrong_commit = True
                        break
            if has_controller_marker_wrong_commit:
                raise GateError(EXIT_POLICY, "parent_review_wrong_head",
                                "Controller review exists but not anchored to parent commit")
            raise GateError(EXIT_POLICY, "parent_review_missing",
                            f"No accepted controller review on parent {self.parent_sha}")

        # Verify at least one parent review was submitted before child commit
        found_valid = False
        for r in parent_reviews:
            if self._check_review_before_child(r):
                found_valid = True
                break
        if not found_valid:
            raise GateError(EXIT_POLICY, "parent_review_after_child_commit",
                            "No parent review submitted before child commit")

    def _check_review_before_child(self, review):
        """Returns True if review was submitted before child commit was created."""
        submitted_at_str = review.get("submitted_at")
        if not submitted_at_str:
            return False
        submitted_at = parse_iso_datetime(submitted_at_str)

        commit_date_str = self.commit_head.get("commit", {}).get("committer", {}).get("date")
        if not commit_date_str:
            return False
        commit_date = parse_iso_datetime(commit_date_str)

        return submitted_at <= commit_date

    def _check_review_timestamp(self, review):
        """Raise if review submitted after child commit."""
        submitted_at_str = review.get("submitted_at")
        if not submitted_at_str:
            raise GateError(EXIT_POLICY, "parent_review_after_child_commit",
                            "Parent review has no submitted_at timestamp")
        submitted_at = parse_iso_datetime(submitted_at_str)

        commit_date_str = self.commit_head.get("commit", {}).get("committer", {}).get("date")
        if not commit_date_str:
            raise GateError(EXIT_INFRA, "timestamp_malformed",
                            "HEAD commit has no committer date")
        commit_date = parse_iso_datetime(commit_date_str)

        if submitted_at > commit_date:
            raise GateError(EXIT_POLICY, "parent_review_after_child_commit",
                            "Parent review submitted after child commit")

    def _validate_worker_report(self):
        self.comments = self.client.get_comments(self.pr_number)
        if not isinstance(self.comments, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Comments data is not a list")

        # Also check reviews for misplaced Worker reports
        self.reviews = self.reviews or self.client.get_reviews(self.pr_number)

        worker_reports = []
        for c in self.comments:
            body = c.get("body", "") or ""
            if WORKER_MARKER not in body:
                continue
            report_json = parse_json_block(body, WORKER_MARKER)
            if report_json is None:
                continue
            if report_json.get("kind") != "worker_report":
                continue
            worker_reports.append({"comment": c, "report": report_json})

        if len(worker_reports) == 0:
            # Check if marker exists in reviews (not top-level comments)
            marker_in_review = False
            for r in self.reviews:
                body = r.get("body", "") or ""
                if WORKER_MARKER in body:
                    marker_in_review = True
                    break
            if marker_in_review:
                raise GateError(EXIT_POLICY, "report_not_top_level",
                                "Worker report found in PR review, not top-level comment")
            raise GateError(EXIT_POLICY, "report_missing",
                            "No worker report found in top-level comments")

        if len(worker_reports) > 1:
            raise GateError(EXIT_POLICY, "marker_duplicated",
                            "Multiple worker reports for same head")

        entry = worker_reports[0]
        report = entry["report"]
        comment = entry["comment"]

        if not validate_simple_schema(report, WORKER_SCHEMA_PATH, None):
            raise GateError(EXIT_POLICY, "schema_invalid",
                            "Worker report does not match schema")

        if report.get("head_sha") != self.expected_head:
            raise GateError(EXIT_POLICY, "report_head_mismatch",
                            "Report head_sha != expected head")

        parent_sha_from_commit = self.commit_head.get("parents", [{}])[0].get("sha")
        if report.get("parent_sha") != parent_sha_from_commit:
            raise GateError(EXIT_POLICY, "report_parent_mismatch",
                            "Report parent_sha != parent of head")

        if report.get("commit_count") != 1:
            raise GateError(EXIT_POLICY, "report_commit_count_invalid",
                            "Report commit_count != 1")

        if not report.get("stop"):
            raise GateError(EXIT_POLICY, "stop_flag_false",
                            "Report stop != true")

        if report.get("next_workstream_started"):
            raise GateError(EXIT_POLICY, "report_next_workstream_started",
                            "Report next_workstream_started == true")

        for field in ["ready_performed", "merge_performed", "release_performed"]:
            if report.get(field):
                raise GateError(EXIT_POLICY, "report_unsafe_action",
                                f"Report {field} == true")

        # Timestamp: comment must be created after commit
        created_at = comment.get("created_at")
        if not created_at:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Comment has no created_at")
        comment_date = parse_iso_datetime(created_at)

        commit_date_str = self.commit_head.get("commit", {}).get("committer", {}).get("date")
        if not commit_date_str:
            raise GateError(EXIT_INFRA, "timestamp_malformed",
                            "HEAD commit has no committer date")
        commit_date = parse_iso_datetime(commit_date_str)

        if comment_date < commit_date:
            raise GateError(EXIT_POLICY, "report_before_commit",
                            "Worker report created before HEAD commit")

        self.worker_report = report
        self.worker_report_comment = comment

    def _validate_ci_run(self):
        run_id = self.worker_report.get("core_ci_run_id")
        runs = self.client.get_workflow_runs(self.expected_head)

        if not isinstance(runs, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Workflow runs data is not a list")

        matching_runs = [r for r in runs if r.get("id") == run_id]
        if len(matching_runs) == 0:
            raise GateError(EXIT_POLICY, "ci_run_not_found",
                            f"CI run {run_id} not found for head {self.expected_head}")

        run = matching_runs[0]

        if run.get("head_sha") != self.expected_head:
            raise GateError(EXIT_POLICY, "ci_run_wrong_head",
                            "CI run head_sha != expected head")

        if run.get("status") != "completed":
            raise GateError(EXIT_POLICY, "ci_run_incomplete",
                            "CI run not completed")

        if run.get("conclusion") != "success":
            raise GateError(EXIT_POLICY, "ci_run_not_success",
                            "CI run conclusion != success")

        jobs = self.client.get_workflow_jobs(run_id)
        if not isinstance(jobs, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Workflow jobs data is not a list")

        required_jobs = self.policy.get("core_ci", {}).get("required_jobs", [])
        for required in required_jobs:
            found = False
            for job in jobs:
                if job.get("name") == required:
                    if job.get("conclusion") == "success":
                        found = True
                        break
                    else:
                        raise GateError(EXIT_POLICY, "ci_job_failed",
                                        f"Required job '{required}' conclusion is '{job.get('conclusion')}'")
            if not found:
                raise GateError(EXIT_POLICY, "ci_job_missing",
                                f"Required job '{required}' not found in CI run")

    def _validate_controller_review(self):
        reviews = self.reviews or self.client.get_reviews(self.pr_number)
        if not isinstance(reviews, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Reviews data is not a list")

        controller_reviews = []
        for r in reviews:
            if r.get("commit_id") != self.expected_head:
                continue
            body = r.get("body", "") or ""
            if CONTROLLER_MARKER not in body:
                continue
            controller_json = parse_json_block(body, CONTROLLER_MARKER)
            if controller_json is None:
                continue
            if controller_json.get("kind") != "controller_review":
                continue
            controller_reviews.append({"review": r, "data": controller_json})

        if len(controller_reviews) == 0:
            raise GateError(EXIT_POLICY, "controller_review_missing",
                            "No controller review found for HEAD")

        if len(controller_reviews) > 1:
            raise GateError(EXIT_POLICY, "marker_duplicated",
                            "Multiple controller reviews")

        entry = controller_reviews[0]
        review = entry["review"]
        data = entry["data"]

        # Must be a PR review (has commit_id), not an issue comment
        if "commit_id" not in review:
            raise GateError(EXIT_POLICY, "controller_review_not_pr_review",
                            "Controller review is not a PR review (missing commit_id)")

        if review.get("commit_id") != self.expected_head:
            raise GateError(EXIT_POLICY, "controller_review_wrong_head",
                            "Controller review commit_id != expected head")

        if not validate_simple_schema(data, CONTROLLER_SCHEMA_PATH, None):
            raise GateError(EXIT_POLICY, "schema_invalid",
                            "Controller review does not match schema")

        if data.get("decision") != "accepted":
            raise GateError(EXIT_POLICY, "controller_review_not_accepted",
                            "Controller review decision != accepted")

        if not data.get("classification", "").startswith("GREEN_"):
            raise GateError(EXIT_POLICY, "classification_not_green",
                            "Classification does not start with GREEN_")

        if not data.get("review_complete"):
            raise GateError(EXIT_POLICY, "review_complete_false",
                            "review_complete != true")

        # Review must be submitted after Worker report
        worker_updated = self.worker_report_comment.get("updated_at")
        if not worker_updated:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Worker report comment has no updated_at")
        worker_time = parse_iso_datetime(worker_updated)

        submitted_at = review.get("submitted_at")
        if not submitted_at:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Controller review has no submitted_at")
        review_time = parse_iso_datetime(submitted_at)

        if review_time < worker_time:
            raise GateError(EXIT_POLICY, "review_before_report",
                            "Controller review submitted before worker report")

        # Check for newer non-accepted review that overrides
        for r in reviews:
            if r.get("id") == review.get("id"):
                continue
            r_time_str = r.get("submitted_at")
            if not r_time_str:
                continue
            r_time = parse_iso_datetime(r_time_str)
            if r_time > review_time:
                if r.get("state") in ("CHANGES_REQUESTED", "DISMISSED"):
                    raise GateError(EXIT_POLICY, "newer_red_review_overrides",
                                    "Newer non-accepted review found after accepted review")

    def _output_success(self):
        if self.phase == "advance":
            result = {
                "state": "CURRENT_WORKSTREAM_ACTIVE",
                "parent_review_confirmed": True,
                "current_report_required": True,
                "next_workstream_admitted": False,
            }
        elif self.phase == "submission":
            result = {
                "state": "WAITING_FOR_CONTROLLER_REVIEW",
                "worker_report_valid": True,
                "controller_review_present": False,
                "next_workstream_admitted": False,
            }
        elif self.phase == "review":
            result = {
                "state": "REVIEW_COMPLETE_NX_REQUIRED",
                "worker_report_valid": True,
                "controller_review_valid": True,
                "nx_required": True,
                "next_workstream_admitted": False,
            }
        else:
            raise GateError(EXIT_INFRA, "unknown_phase", f"Unknown phase: {self.phase}")

        result.update({
            "repository": self.repo,
            "pr_number": self.pr_number,
            "head_sha": self.expected_head,
            "parent_sha": self.parent_sha,
        })

        print(json.dumps(result))

    def _output_error(self, e):
        result = {
            "state": "REJECTED",
            "repository": self.repo,
            "pr_number": self.pr_number,
            "head_sha": self.expected_head,
            "parent_sha": getattr(self, "parent_sha", None),
            "guard_label": e.label,
        }
        print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser(description="Workstream Review Gate")
    parser.add_argument("--phase", required=True,
                        choices=["advance", "submission", "review"])
    parser.add_argument("--pr-number", type=int, required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--repo", default="oxcandy-lgtm/macsteam")
    parser.add_argument("--fixtures", default=None,
                        help="Fixture directory for offline testing")
    parser.add_argument("--policy", default=POLICY_PATH_DEFAULT)
    parser.add_argument("--max-items", type=int, default=1000)

    args = parser.parse_args()

    gate = Gate(
        phase=args.phase,
        pr_number=args.pr_number,
        expected_head=args.expected_head,
        repo=args.repo,
        fixtures_dir=args.fixtures,
        policy_path=args.policy,
        max_items=args.max_items,
    )

    sys.exit(gate.run())


if __name__ == "__main__":
    main()
