#!/usr/bin/env python3
"""
Workstream Review Gate — U1R18-R7-FIX1

Enforces sequential workstream advancement on a single PR.
Verifies that each commit has a preceding controller review before
the next workstream can start.

Usage (live mode):
  python3 scripts/workstage-review-gate.py \\
    --phase advance --pr-number 2 --expected-head <SHA>

Usage (fixture/offline mode):
  python3 scripts/workstage-review-gate.py \\
    --phase submission --pr-number 2 --expected-head <SHA> \\
    --fixtures scripts/workstage-review-gate-fixtures/green/submission

Exit codes:
  0 = phase contract satisfied
  1 = policy/protocol violation (guard label in output)
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

SUPPORTED_SCHEMA_KEYWORDS = {
    "$schema", "$id", "title", "description", "type",
    "required", "properties", "additionalProperties",
    "const", "enum", "pattern", "minimum", "maximum",
    "exclusiveMinimum", "exclusiveMaximum",
    "minItems", "maxItems", "uniqueItems", "items",
    "minLength", "schema_version",
}


class GateError(Exception):
    def __init__(self, exit_code, label, message=""):
        super().__init__(message)
        self.exit_code = exit_code
        self.label = label
        self.message = message


# === JSON Schema Validator (stdlib only) ===

class SchemaValidator:
    """Pure-stdlib JSON Schema draft-07 subset validator."""

    def __init__(self):
        self._schema_path = "unknown"

    def validate(self, doc, schema, schema_path="unknown"):
        self._schema_path = schema_path
        return self._validate_node(doc, schema, "root")

    def _validate_node(self, doc, schema, path):
        if not isinstance(schema, dict):
            raise GateError(
                EXIT_INFRA, "unsupported_schema_contract",
                f"Schema at {path} is not an object")

        for key in schema:
            if key not in SUPPORTED_SCHEMA_KEYWORDS:
                raise GateError(
                    EXIT_INFRA, "unsupported_schema_contract",
                    f"Unsupported schema keyword: {key}")

        if "const" in schema:
            if doc != schema["const"]:
                return False

        if "enum" in schema:
            if doc not in schema["enum"]:
                return False

        if "type" in schema:
            if not self._check_type(doc, schema["type"]):
                return False

        if isinstance(doc, str) and "pattern" in schema:
            if not re.fullmatch(schema["pattern"], doc):
                return False

        if "minLength" in schema and isinstance(doc, str):
            if len(doc) < schema["minLength"]:
                return False

        if "minimum" in schema and isinstance(doc, (int, float)) and not isinstance(doc, bool):
            if doc < schema["minimum"]:
                return False

        if "exclusiveMinimum" in schema and isinstance(doc, (int, float)) and not isinstance(doc, bool):
            if doc <= schema["exclusiveMinimum"]:
                return False

        if "maximum" in schema and isinstance(doc, (int, float)) and not isinstance(doc, bool):
            if doc > schema["maximum"]:
                return False

        if isinstance(doc, list):
            if "minItems" in schema and len(doc) < schema["minItems"]:
                return False
            if "maxItems" in schema and len(doc) > schema["maxItems"]:
                return False
            if schema.get("uniqueItems"):
                seen = set()
                for item in doc:
                    key = json.dumps(item, sort_keys=True)
                    if key in seen:
                        return False
                    seen.add(key)
            if "items" in schema:
                item_schema = schema["items"]
                if isinstance(item_schema, dict):
                    for i, item in enumerate(doc):
                        if not self._validate_node(item, item_schema, f"{path}[{i}]"):
                            return False

        if isinstance(doc, dict):
            if "required" in schema:
                for field in schema["required"]:
                    if field not in doc:
                        return False

            props = schema.get("properties", {})
            additional = schema.get("additionalProperties", True)

            for key in doc:
                if key not in props and additional is False:
                    return False

            for key, prop_schema in props.items():
                if key in doc:
                    if not self._validate_node(doc[key], prop_schema, f"{path}.{key}"):
                        return False

        return True

    def _check_type(self, doc, type_spec):
        if isinstance(type_spec, list):
            for t in type_spec:
                if self._check_single_type(doc, t):
                    return True
            return False
        return self._check_single_type(doc, type_spec)

    @staticmethod
    def _check_single_type(doc, t):
        if t == "object":
            return isinstance(doc, dict)
        if t == "array":
            return isinstance(doc, list)
        if t == "string":
            return isinstance(doc, str)
        if t == "boolean":
            return isinstance(doc, bool)
        if t == "integer":
            return isinstance(doc, int) and not isinstance(doc, bool)
        if t == "number":
            return isinstance(doc, (int, float)) and not isinstance(doc, bool)
        if t == "null":
            return doc is None
        return False


def parse_json_block(body, marker):
    """Extract JSON from a fenced block following the marker in a text body.

    Returns (json_obj, marker_count, block_count) or (None, marker_count, block_count).
    """
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


def load_schema(schema_path):
    """Load and validate a JSON schema file. Returns the schema dict."""
    if not os.path.exists(schema_path):
        raise GateError(EXIT_INFRA, "schema_missing",
                        f"Schema file not found: {schema_path}")
    try:
        with open(schema_path) as f:
            schema = json.load(f)
    except json.JSONDecodeError:
        raise GateError(EXIT_INFRA, "schema_malformed",
                        f"Schema file is not valid JSON: {schema_path}")

    validator = SchemaValidator()
    try:
        validator.validate(schema, schema, schema_path)
    except GateError:
        raise
    return schema


def validate_document(doc, schema, schema_path):
    """Validate a document against a JSON schema. Returns True/False."""
    if not os.path.exists(schema_path):
        raise GateError(EXIT_INFRA, "schema_missing",
                        f"Schema file not found: {schema_path}")
    try:
        with open(schema_path) as f:
            schema = json.load(f)
    except json.JSONDecodeError:
        raise GateError(EXIT_INFRA, "schema_malformed",
                        f"Schema file is not valid JSON: {schema_path}")

    validator = SchemaValidator()
    return validator.validate(doc, schema, schema_path)


class GitHubClient:
    """GitHub API client — live mode via gh CLI or fixture mode via local JSON."""

    MAX_PAGES = 100
    MAX_ITEMS_PER_PAGE = 100

    def __init__(self, repo, fixtures_dir=None, max_items=1000):
        self.repo = repo
        self.fixtures_dir = fixtures_dir
        self.max_items = max_items
        self._page_count = 0

    def get_pr(self, pr_number):
        if self.fixtures_dir:
            return self._load("pr.json")
        return self._gh_object(f"pulls/{pr_number}")

    def get_commit(self, sha):
        if self.fixtures_dir:
            if sha == self._expected_head:
                return self._load("commit_HEAD.json")
            return self._load("commit_PARENT.json")
        return self._gh_object(f"commits/{sha}")

    def get_commit_files(self, sha):
        if self.fixtures_dir:
            return self._load("files.json")
        commit = self._gh_object(f"commits/{sha}")
        return commit.get("files", [])

    def get_comments(self, pr_number):
        if self.fixtures_dir:
            return self._load("comments.json")
        return self._gh_paginated(f"issues/{pr_number}/comments")

    def get_reviews(self, pr_number):
        if self.fixtures_dir:
            reviews = self._load("reviews.json")
            seen_ids = set()
            for r in reviews:
                if isinstance(r, dict) and "id" in r:
                    rid = r["id"]
                    if rid in seen_ids:
                        raise GateError(EXIT_INFRA, "pagination_duplicate_id",
                                        f"Duplicate review ID in fixtures: {rid}")
                    seen_ids.add(rid)
            return reviews
        return self._gh_paginated(f"pulls/{pr_number}/reviews")

    def get_review_by_id(self, review_id):
        if self.fixtures_dir:
            reviews = self._load("reviews.json")
            for r in reviews:
                if r.get("id") == review_id:
                    return r
            raise GateError(EXIT_INFRA, "api_404_reviews",
                            f"Review {review_id} not found in fixtures")
        return self._gh_object(f"pulls/{self._pr_number}/reviews/{review_id}")

    def get_workflow_runs(self, head_sha):
        if self.fixtures_dir:
            data = self._load("runs.json")
            return data.get("workflow_runs", []) if isinstance(data, dict) else data
        pages = self._gh_paginated_pages(f"actions/runs?head_sha={head_sha}")
        return [run for page in pages for run in page.get("workflow_runs", [])]

    def get_workflow_jobs(self, run_id):
        if self.fixtures_dir:
            data = self._load("jobs.json")
            return data.get("jobs", []) if isinstance(data, dict) else data
        pages = self._gh_paginated_pages(f"actions/runs/{run_id}/jobs")
        return [job for page in pages for job in page.get("jobs", [])]

    def get_workflow_run_by_id(self, run_id):
        if self.fixtures_dir:
            data = self._load("runs.json")
            runs = data.get("workflow_runs", []) if isinstance(data, dict) else data
            for run in runs:
                if run.get("id") == run_id:
                    return run
            return None
        return self._gh_object(f"actions/runs/{run_id}")

    def set_context(self, expected_head, parent_sha):
        self._expected_head = expected_head
        self._parent_sha = parent_sha

    def set_pr_number(self, pr_number):
        self._pr_number = pr_number

    def _load(self, filename):
        path = os.path.join(self.fixtures_dir, filename)
        if not os.path.exists(path):
            raise GateError(EXIT_INFRA, "fixture_missing",
                            f"Fixture file missing: {filename}")
        try:
            with open(path) as f:
                return json.load(f)
        except json.JSONDecodeError as e:
            raise GateError(EXIT_INFRA, "fixture_json_malformed",
                            f"Invalid JSON in {filename}: {e}")

    def _gh_object(self, endpoint):
        """Single-object API call. Returns dict. 404 → exit 2."""
        result = subprocess.run(
            ["gh", "api", f"repos/{self.repo}/{endpoint}"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            if "404" in stderr or "not found" in stderr.lower():
                raise GateError(EXIT_INFRA, "api_404_" + endpoint.split("/")[0],
                                f"GitHub API 404: {endpoint}")
            if "timeout" in stderr.lower() or result.returncode == 124:
                raise GateError(EXIT_INFRA, "timeout",
                                "GitHub API request timed out")
            if "rate limit" in stderr.lower():
                raise GateError(EXIT_INFRA, "rate_limit",
                                "GitHub API rate limited")
            raise GateError(EXIT_INFRA, "api_request_failure", stderr)

        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise GateError(EXIT_INFRA, "pagination_parse_failure",
                            "Failed to parse GitHub API response")

        if not isinstance(data, dict):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            f"GitHub API {endpoint} did not return an object")

        if data.get("message"):
            msg = data["message"].lower()
            if "rate limit" in msg:
                raise GateError(EXIT_INFRA, "rate_limit",
                                "GitHub API rate limited")
            raise GateError(EXIT_INFRA, "api_request_failure",
                            data["message"])

        return data

    def _gh_paginated(self, endpoint):
        """Paginated list API call. Returns flattened list. 404 → exit 2."""
        result = subprocess.run(
            ["gh", "api", f"repos/{self.repo}/{endpoint}",
             "--paginate", "--slurp"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            if "404" in stderr or "not found" in stderr.lower():
                raise GateError(EXIT_INFRA, "api_404_" + endpoint.split("/")[0],
                                f"GitHub API 404: {endpoint}")
            if "timeout" in stderr.lower() or result.returncode == 124:
                raise GateError(EXIT_INFRA, "timeout",
                                "GitHub API request timed out")
            if "rate limit" in stderr.lower():
                raise GateError(EXIT_INFRA, "rate_limit",
                                "GitHub API rate limited")
            raise GateError(EXIT_INFRA, "api_request_failure", stderr)

        try:
            pages = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise GateError(EXIT_INFRA, "pagination_parse_failure",
                            "Failed to parse paginated GitHub API response")

        if not isinstance(pages, list):
            raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                            "Paginated API response is not a list of pages")

        if len(pages) > self.MAX_PAGES:
            raise GateError(EXIT_INFRA, "pagination_page_cap_reached",
                            f"Too many pages: {len(pages)} > {self.MAX_PAGES}")

        flattened = []
        seen_ids = set()

        for page in pages:
            if not isinstance(page, list):
                raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                                "A page in the paginated response is not a list")

            for item in page:
                if not isinstance(item, dict):
                    raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                                    "A page item is not an object")

                if "id" in item:
                    item_id = item["id"]
                    if item_id in seen_ids:
                        raise GateError(EXIT_INFRA, "pagination_duplicate_id",
                                        f"Duplicate ID in paginated results: {item_id}")
                    seen_ids.add(item_id)

                flattened.append(item)

            if len(flattened) > self.max_items:
                raise GateError(EXIT_INFRA, "pagination_item_cap_reached",
                                f"Too many items: {len(flattened)} > {self.max_items}")

        return flattened

    def _gh_paginated_pages(self, endpoint):
        """Paginated API call returning dict-with-array responses.
        Returns list of pages (each page is a dict)."""
        result = subprocess.run(
            ["gh", "api", f"repos/{self.repo}/{endpoint}",
             "--paginate", "--slurp"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            if "404" in stderr or "not found" in stderr.lower():
                raise GateError(EXIT_INFRA, "api_404_" + endpoint.split("/")[0],
                                f"GitHub API 404: {endpoint}")
            if "timeout" in stderr.lower() or result.returncode == 124:
                raise GateError(EXIT_INFRA, "timeout",
                                "GitHub API request timed out")
            if "rate limit" in stderr.lower():
                raise GateError(EXIT_INFRA, "rate_limit",
                                "GitHub API rate limited")
            raise GateError(EXIT_INFRA, "api_request_failure", stderr)

        try:
            pages = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise GateError(EXIT_INFRA, "pagination_parse_failure",
                            "Failed to parse paginated GitHub API response")

        if not isinstance(pages, list):
            raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                            "Paginated API response is not a list of pages")

        return pages

    def _gh_paginated(self, endpoint):
        """Paginated list API call. Returns flattened list. 404 → exit 2."""
        result = subprocess.run(
            ["gh", "api", f"repos/{self.repo}/{endpoint}",
             "--paginate", "--slurp"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            if "404" in stderr or "not found" in stderr.lower():
                raise GateError(EXIT_INFRA, "api_404_" + endpoint.split("/")[0],
                                f"GitHub API 404: {endpoint}")
            if "timeout" in stderr.lower() or result.returncode == 124:
                raise GateError(EXIT_INFRA, "timeout",
                                "GitHub API request timed out")
            if "rate limit" in stderr.lower():
                raise GateError(EXIT_INFRA, "rate_limit",
                                "GitHub API rate limited")
            raise GateError(EXIT_INFRA, "api_request_failure", stderr)

        try:
            pages = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise GateError(EXIT_INFRA, "pagination_parse_failure",
                            "Failed to parse paginated GitHub API response")

        if not isinstance(pages, list):
            raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                            "Paginated API response is not a list of pages")

        if len(pages) > self.MAX_PAGES:
            raise GateError(EXIT_INFRA, "pagination_page_cap_reached",
                            f"Too many pages: {len(pages)} > {self.MAX_PAGES}")

        flattened = []
        seen_ids = set()

        for page in pages:
            if not isinstance(page, list):
                raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                                "A page in the paginated response is not a list")

            for item in page:
                if not isinstance(item, dict):
                    raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                                    "A page item is not an object")

                if "id" in item:
                    item_id = item["id"]
                    if item_id in seen_ids:
                        raise GateError(EXIT_INFRA, "pagination_duplicate_id",
                                        f"Duplicate ID in paginated results: {item_id}")
                    seen_ids.add(item_id)

                flattened.append(item)

            if len(flattened) > self.max_items:
                raise GateError(EXIT_INFRA, "pagination_item_cap_reached",
                                f"Too many items: {len(flattened)} > {self.max_items}")

        return flattened


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
        self.client.set_context(expected_head, None)
        self.client.set_pr_number(pr_number)

        self.pr = None
        self.commit_head = None
        self.commit_parent = None
        self.parent_sha = None
        self.reviews = None
        self.comments = None
        self.worker_report = None
        self.worker_report_comment = None
        self.controller_reviews_found = []
        self.parent_authority = None
        self._reviews_loaded = False

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

        for field in ["repair_authorization", "quarantined_review_ids"]:
            if field not in policy:
                raise GateError(EXIT_INFRA, "policy_malformed",
                                f"Policy missing required field: {field}")

        bootstrap = policy.get("bootstrap", {})
        for field in ["head_sha", "only_child_head", "worker_report_comment_id",
                      "controller_review_id", "classification"]:
            if field not in bootstrap:
                raise GateError(EXIT_INFRA, "policy_malformed",
                                f"Policy bootstrap missing: {field}")

        repair = policy.get("repair_authorization", {})
        for field in ["parent_sha", "review_id", "classification",
                      "required_commit_message", "required_workstream",
                      "single_direct_child_only"]:
            if field not in repair:
                raise GateError(EXIT_INFRA, "policy_malformed",
                                f"Policy repair_authorization missing: {field}")

        return policy

    def run(self):
        try:
            self._validate_pr_state()
            self._validate_head_match()
            self._validate_expected_head_format()
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
        except Exception as e:
            self._output_error(GateError(EXIT_INFRA, "internal_exception", str(e)))
            return EXIT_INFRA

    # === PR state & policy binding ===

    def _validate_pr_state(self):
        self.pr = self.client.get_pr(self.pr_number)

        if not isinstance(self.pr, dict):
            raise GateError(EXIT_INFRA, "object_unparseable", "PR data is not an object")

        head_repo = self.pr.get("head", {}).get("repo", {}).get("full_name", "")
        base_ref = self.pr.get("base", {}).get("ref", "")
        head_ref = self.pr.get("head", {}).get("ref", "")
        pr_number = self.pr.get("number")

        policy_repo = self.policy.get("repository", "")
        policy_pr = self.policy.get("pr_number")
        policy_branch = self.policy.get("branch", "")
        policy_base = self.policy.get("base_branch", "")

        if head_repo != policy_repo:
            raise GateError(EXIT_POLICY, "repository_mismatch",
                            f"PR repo {head_repo} != policy repo {policy_repo}")
        if pr_number != policy_pr:
            raise GateError(EXIT_POLICY, "pr_number_mismatch",
                            f"PR number {pr_number} != policy {policy_pr}")
        if head_ref != policy_branch:
            raise GateError(EXIT_POLICY, "head_branch_mismatch",
                            f"Head ref {head_ref} != policy branch {policy_branch}")
        if base_ref != policy_base:
            raise GateError(EXIT_POLICY, "base_branch_mismatch",
                            f"Base ref {base_ref} != policy base {policy_base}")

        if self.pr.get("state", "").upper() != "OPEN":
            raise GateError(EXIT_POLICY, "pr_closed",
                            f"PR state is {self.pr.get('state')}, expected OPEN")

        if not self.pr.get("draft", False):
            raise GateError(EXIT_POLICY, "pr_not_draft", "PR is not draft")

        if self.pr.get("merged", False):
            raise GateError(EXIT_POLICY, "pr_merged", "PR is merged")

        mergeable = self.pr.get("mergeable")
        if mergeable is None or mergeable == "UNKNOWN" or mergeable == "unknown":
            if self.fixtures_dir:
                raise GateError(EXIT_INFRA, "mergeable_unknown_after_retry",
                                "PR mergeable is unknown (fixture mode, no retry)")
            for attempt in range(5):
                import time
                time.sleep(10)
                self.pr = self.client.get_pr(self.pr_number)
                mergeable = self.pr.get("mergeable")
                if mergeable is not None and mergeable != "UNKNOWN":
                    break
            if mergeable is None or mergeable == "UNKNOWN" or mergeable == "unknown":
                raise GateError(EXIT_INFRA, "mergeable_unknown_after_retry",
                                "PR mergeable is unknown after bounded retry")

        if mergeable is True or mergeable == "MERGEABLE" or str(mergeable).upper() == "MERGEABLE":
            pass
        else:
            raise GateError(EXIT_POLICY, "pr_not_mergeable",
                            f"PR not mergeable (mergeable={mergeable})")

    def _validate_expected_head_format(self):
        if not re.fullmatch(r"^[a-f0-9]{40}$", self.expected_head):
            raise GateError(EXIT_POLICY, "expected_head_invalid",
                            f"Expected head is not a valid 40-char SHA: {self.expected_head}")

    def _validate_head_match(self):
        head_sha = self.pr.get("head", {}).get("sha")
        if head_sha != self.expected_head:
            raise GateError(EXIT_POLICY, "head_sha_mismatch",
                            f"PR head {head_sha} != expected {self.expected_head}")

    def _validate_single_parent(self):
        self.commit_head = self.client.get_commit(self.expected_head)
        parents = self.commit_head.get("parents", [])
        if len(parents) != 1:
            raise GateError(EXIT_POLICY, "merge_commit_rejected",
                            f"Expected 1 parent, got {len(parents)}")
        self.parent_sha = parents[0].get("sha")
        if not self.parent_sha:
            raise GateError(EXIT_INFRA, "commit_parent_unavailable",
                            "No parent SHA in commit data")
        if not re.fullmatch(r"^[a-f0-9]{40}$", self.parent_sha):
            raise GateError(EXIT_INFRA, "commit_parent_unavailable",
                            f"Parent SHA is not valid: {self.parent_sha}")

        self.commit_parent = self.client.get_commit(self.parent_sha)

    # === Parent review routing ===

    def _validate_parent_review(self):
        bootstrap = self.policy.get("bootstrap", {})
        bootstrap_head = bootstrap.get("head_sha")
        bootstrap_child = bootstrap.get("only_child_head")

        repair = self.policy.get("repair_authorization", {})
        repair_parent = repair.get("parent_sha")

        self._load_reviews()

        if self.parent_sha == bootstrap_head and self.expected_head == bootstrap_child:
            self.parent_authority = "bootstrap"
            self._validate_bootstrap_review(bootstrap)
        elif self.parent_sha == repair_parent:
            self.parent_authority = "repair_authorization"
            self._validate_repair_authorization(repair)
        else:
            self.parent_authority = "controller_review"
            self._validate_normal_parent_review()

    def _load_reviews(self):
        if not self._reviews_loaded:
            self.reviews = self.client.get_reviews(self.pr_number)
            if not isinstance(self.reviews, list):
                raise GateError(EXIT_INFRA, "object_unparseable",
                                "Reviews data is not a list")
            self._reviews_loaded = True

    # === Bootstrap validation ===

    def _validate_bootstrap_review(self, bootstrap):
        bootstrap_review_id = bootstrap.get("controller_review_id")
        bootstrap_head = bootstrap.get("head_sha")
        classification = bootstrap.get("classification", "")

        found = None
        for r in self.reviews:
            if not isinstance(r, dict):
                continue
            if r.get("id") == bootstrap_review_id:
                found = r
                break

        if not found:
            raise GateError(EXIT_POLICY, "bootstrap_review_missing",
                            "Bootstrap controller review not found by ID")

        if found.get("commit_id") != bootstrap_head:
            raise GateError(EXIT_POLICY, "bootstrap_wrong_commit",
                            "Bootstrap review has wrong commit_id")

        if found.get("state") != "APPROVED":
            raise GateError(EXIT_POLICY, "bootstrap_review_missing",
                            "Bootstrap review is not APPROVED")

        review_body = found.get("body", "") or ""
        if classification not in review_body:
            raise GateError(EXIT_POLICY, "bootstrap_policy_green_without_body_evidence",
                            "Bootstrap review body does not contain exact classification")

        self._check_review_before_child(found)

    # === Repair authorization validation ===

    def _validate_repair_authorization(self, repair):
        review_id = repair.get("review_id")
        parent_sha = repair.get("parent_sha")
        classification = repair.get("classification", "")
        required_msg = repair.get("required_commit_message", "")
        required_ws = repair.get("required_workstream", "")
        quarantined = set(self.policy.get("quarantined_review_ids", []))

        # Fetch the exact review object
        review = self.client.get_review_by_id(review_id)
        if not isinstance(review, dict):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Repair review object is not a dict")

        if review.get("id") != review_id:
            raise GateError(EXIT_POLICY, "repair_wrong_review_id",
                            "Repair review ID mismatch")

        if review.get("commit_id") != parent_sha:
            raise GateError(EXIT_POLICY, "repair_wrong_parent",
                            "Repair review commit_id != repair parent_sha")

        review_body = review.get("body", "") or ""
        if classification not in review_body:
            raise GateError(EXIT_POLICY, "repair_wrong_classification",
                            "Repair review body does not contain exact classification")

        if "R7" not in review_body or "repair" not in review_body.lower():
            raise GateError(EXIT_POLICY, "repair_wrong_classification",
                            "Repair review body does not contain R7 repair instruction")

        if review_id in quarantined:
            raise GateError(EXIT_POLICY, "repair_quarantined_review_used",
                            "Repair review ID is quarantined")

        # Validate child commit
        commit_message = self.commit_head.get("commit", {}).get("message", "")
        if not commit_message:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "HEAD commit has no message")

        first_line = commit_message.split("\n")[0].strip()
        if first_line != required_msg:
            raise GateError(EXIT_POLICY, "repair_wrong_commit_message",
                            f"Commit message first line mismatch: '{first_line}' != '{required_msg}'")

        if not re.search(rf"^Workstream:\s*{re.escape(required_ws)}\s*$", commit_message, re.MULTILINE):
            raise GateError(EXIT_POLICY, "repair_wrong_workstream_trailer",
                            "Commit message missing Workstream trailer")

        # single_direct_child_only: parent must be exact repair parent
        if self.parent_sha != parent_sha:
            raise GateError(EXIT_POLICY, "repair_reused_after_fix1",
                            "Repair authorization parent mismatch on child")

        # Changed paths validation
        files = self._get_changed_files()
        for filepath in files:
            if not self._is_allowed_path(filepath):
                raise GateError(EXIT_POLICY, "repair_forbidden_path",
                                f"Changed file not in allowed paths: {filepath}")
            if filepath.startswith("Sources/") or filepath.startswith("Tests/"):
                raise GateError(EXIT_POLICY, "repair_production_source_changed",
                                f"Production source changed: {filepath}")

    def _get_changed_files(self):
        if self.fixtures_dir:
            files_data = self.client._load("files.json")
            if isinstance(files_data, dict):
                files_list = files_data.get("files", [])
            elif isinstance(files_data, list):
                files_list = files_data
            else:
                return []
        else:
            files_list = self.client.get_commit_files(self.expected_head)
        return [f.get("filename", f) if isinstance(f, dict) else f for f in files_list]

    @staticmethod
    def _is_allowed_path(filepath):
        ALLOWED = {
            ".github/workflows/ci.yml",
            ".github/workflows/workstage-review-gate.yml",
            ".github/workstage-review-gate-policy.json",
            "Contracts/controller-review.schema.json",
            "Contracts/workstream-report.schema.json",
            "docs/WORKSTREAM_REVIEW_GATE.md",
            "scripts/workstage-review-gate.py",
            "scripts/test-workstage-review-gate.sh",
        }
        if filepath in ALLOWED:
            return True
        if filepath.startswith("scripts/workstage-review-gate-fixtures/"):
            return True
        return False

    # === Normal parent review validation ===

    def _validate_normal_parent_review(self):
        if not self.reviews or not isinstance(self.reviews, list):
            self._check_parent_review_marker_wrong_commit()
            raise GateError(EXIT_POLICY, "parent_review_missing",
                            f"No reviews found on PR for parent {self.parent_sha}")

        # Collect all reviews on the parent commit
        parent_reviews = []
        for r in self.reviews:
            if not isinstance(r, dict):
                continue
            if r.get("commit_id") != self.parent_sha:
                continue
            parent_reviews.append(r)

        if not parent_reviews:
            self._check_parent_review_marker_wrong_commit()
            raise GateError(EXIT_POLICY, "parent_review_missing",
                            f"No reviews found on PR for parent {self.parent_sha}")

        # Separate marker-present and non-marker reviews
        marker_reviews = []  # reviews with CONTROLLER_MARKER
        non_marker_commented = []  # COMMENTED/APPROVED without marker
        latest_changes_requested = None
        latest_dismissed = None

        for r in parent_reviews:
            state = r.get("state", "")
            body = r.get("body", "") or ""
            submitted_at_str = r.get("submitted_at")

            if state == "DISMISSED":
                if latest_dismissed is None or (
                    submitted_at_str and latest_dismissed.get("submitted_at") and
                    submitted_at_str > latest_dismissed["submitted_at"]
                ):
                    latest_dismissed = r
                continue

            if state == "CHANGES_REQUESTED":
                if latest_changes_requested is None or (
                    submitted_at_str and latest_changes_requested.get("submitted_at") and
                    submitted_at_str > latest_changes_requested["submitted_at"]
                ):
                    latest_changes_requested = r
                continue

            if state not in ("COMMENTED", "APPROVED"):
                continue

            marker_count = body.count(CONTROLLER_MARKER)
            if marker_count == 0:
                non_marker_commented.append(r)
                continue

            if marker_count > 1:
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "marker_duplicated",
                                       "submitted_at": submitted_at_str})
                continue

            json_data, mc, bc = parse_json_block(body, CONTROLLER_MARKER)

            if json_data is None:
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "bad_json",
                                       "submitted_at": submitted_at_str})
                continue

            if bc > 1:
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "json_blocks_duplicated",
                                       "submitted_at": submitted_at_str})
                continue

            if not validate_document(json_data, CONTROLLER_SCHEMA_PATH, CONTROLLER_SCHEMA_PATH):
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "schema_invalid",
                                       "submitted_at": submitted_at_str})
                continue

            if json_data.get("kind") != "controller_review":
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "bad_kind",
                                       "submitted_at": submitted_at_str})
                continue

            if json_data.get("head_sha") != self.parent_sha:
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "controller_json_head_mismatch",
                                       "submitted_at": submitted_at_str})
                continue

            quarantined = set(self.policy.get("quarantined_review_ids", []))
            if r.get("id") in quarantined:
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "quarantined",
                                       "submitted_at": submitted_at_str})
                continue

            decision = json_data.get("decision")
            if decision == "rejected":
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "rejected",
                                       "submitted_at": submitted_at_str})
                continue

            if decision != "accepted":
                continue

            errors = self._validate_controller_json(json_data)
            if errors:
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": errors[0],
                                       "submitted_at": submitted_at_str})
                continue

            if not self._check_review_before_child(r):
                marker_reviews.append({"review": r, "valid": False,
                                       "reason": "after_child",
                                       "submitted_at": submitted_at_str})
                continue

            marker_reviews.append({"review": r, "valid": True, "submitted_at": submitted_at_str})

        # If no marker reviews, handle non-marker and empty cases
        if not marker_reviews:
            if non_marker_commented:
                raise GateError(EXIT_POLICY, "parent_review_commented_without_marker",
                                "COMMENTED/APPROVED review without controller marker on parent")
            # Check for CHANGES_REQUESTED on parent without marker reviews
            if latest_changes_requested:
                raise GateError(EXIT_POLICY, "selected_changes_requested",
                                "Latest parent review is CHANGES_REQUESTED")
            if latest_dismissed:
                raise GateError(EXIT_POLICY, "selected_dismissed",
                                "Latest parent review is DISMISSED")

            # Check if controller marker is in issue comments instead of PR reviews
            if self.comments is None:
                self.comments = self.client.get_comments(self.pr_number)
            if isinstance(self.comments, list):
                for c in getattr(self, "comments", []):
                    body = c.get("body", "") or ""
                    if CONTROLLER_MARKER in body:
                        raise GateError(EXIT_POLICY, "parent_review_issue_comment_only",
                                        "Controller review found as issue comment, not PR review")

            self._check_parent_review_marker_wrong_commit()
            raise GateError(EXIT_POLICY, "parent_review_missing",
                            f"No accepted controller review on parent {self.parent_sha}")

        # Sort marker reviews by submitted_at for latest-decision authority
        marker_reviews.sort(
            key=lambda x: x["submitted_at"] or "0000-01-01T00:00:00Z"
        )

        # Check if CHANGES_REQUESTED or DISMISSED review overrides the latest marker review
        latest_marker = marker_reviews[-1]
        latest_marker_ts = latest_marker["submitted_at"] or ""

        if latest_changes_requested:
            cr_ts = latest_changes_requested.get("submitted_at") or ""
            if cr_ts > latest_marker_ts:
                raise GateError(EXIT_POLICY, "selected_changes_requested",
                                "Newer CHANGES_REQUESTED review overrides accepted controller review")

        if latest_dismissed:
            d_ts = latest_dismissed.get("submitted_at") or ""
            if d_ts > latest_marker_ts:
                raise GateError(EXIT_POLICY, "selected_dismissed",
                                "Newer DISMISSED review overrides accepted controller review")

        # Check latest decision
        if not latest_marker["valid"]:
            reason = latest_marker["reason"]
            REASON_MAP = {
                "changes_requested": "selected_changes_requested",
                "dismissed": "selected_dismissed",
                "rejected": "latest_rejected_overrides_old_green",
                "after_child": "parent_review_after_child",
                "quarantined": "quarantined_self_review_rejected",
                "marker_duplicated": "controller_marker_duplicated_in_body",
                "json_blocks_duplicated": "controller_json_blocks_duplicated",
                "bad_json": "parent_review_approved_with_bad_json",
                "schema_invalid": "parent_review_approved_with_bad_json",
                "bad_kind": "parent_review_approved_with_bad_json",
                "controller_json_head_mismatch": "controller_json_head_mismatch",
            }
            guard = REASON_MAP.get(reason, reason)
            raise GateError(EXIT_POLICY, guard,
                            f"Latest parent review invalid: {reason}")

        # Latest marker review is valid — parent review confirmed


    def _check_parent_review_marker_wrong_commit(self):
        """Check if a controller marker exists on a wrong commit."""
        for r in self.reviews:
            if not isinstance(r, dict):
                continue
            body = r.get("body", "") or ""
            if CONTROLLER_MARKER in body:
                if r.get("commit_id") != self.parent_sha:
                    raise GateError(EXIT_POLICY, "parent_review_wrong_head",
                                    "Controller review exists but not anchored to parent commit")

    def _validate_controller_json(self, data):
        """Validate a controller review JSON block. Returns list of error guard labels."""
        errors = []
        if not isinstance(data, dict):
            errors.append("schema_invalid")
            return errors

        if data.get("kind") != "controller_review":
            errors.append("schema_invalid")
            return errors

        if data.get("decision") != "accepted":
            errors.append("controller_review_not_accepted")
            return errors

        classification = data.get("classification", "")
        if not classification.startswith("GREEN_"):
            errors.append("controller_classification_not_green")

        if not data.get("review_complete", False):
            errors.append("controller_review_complete_false")

        if not data.get("nx_required_for_next_workstream", False):
            errors.append("controller_nx_required_false")

        if data.get("ready_authorized", False):
            errors.append("controller_ready_true")

        if data.get("merge_authorized", False):
            errors.append("controller_merge_true")

        if data.get("release_authorized", False):
            errors.append("controller_release_true")

        return errors

    def _check_review_before_child(self, review):
        submitted_at_str = review.get("submitted_at")
        if not submitted_at_str:
            return False
        try:
            submitted_at = parse_iso_datetime(submitted_at_str)
        except GateError:
            return False

        commit_date_str = self.commit_head.get("commit", {}).get("committer", {}).get("date")
        if not commit_date_str:
            return False
        commit_date = parse_iso_datetime(commit_date_str)

        return submitted_at <= commit_date

    def _check_review_timestamp(self, review):
        submitted_at_str = review.get("submitted_at")
        if not submitted_at_str:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Parent review has no submitted_at timestamp")
        submitted_at = parse_iso_datetime(submitted_at_str)

        commit_date_str = self.commit_head.get("commit", {}).get("committer", {}).get("date")
        if not commit_date_str:
            raise GateError(EXIT_INFRA, "timestamp_malformed",
                            "HEAD commit has no committer date")
        commit_date = parse_iso_datetime(commit_date_str)

        if submitted_at > commit_date:
            raise GateError(EXIT_POLICY, "parent_review_after_child",
                            "Parent review submitted after child commit")

    # === Worker report validation ===

    def _validate_worker_report(self):
        self.comments = self.client.get_comments(self.pr_number)
        if not isinstance(self.comments, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Comments data is not a list")

        if not self._reviews_loaded:
            self._load_reviews()

        worker_reports_current = []
        worker_reports_historical = []
        marker_in_review = False
        marker_in_inline = False

        for c in self.comments:
            body = c.get("body", "") or ""
            if WORKER_MARKER not in body:
                continue

            if c.get("in_reply_to_id"):
                raise GateError(EXIT_POLICY, "report_reply",
                                "Worker report is a reply to another comment")

            if c.get("path") or c.get("position"):
                raise GateError(EXIT_POLICY, "report_inline",
                                "Worker report is an inline comment")

            report_json, marker_count, block_count = parse_json_block(body, WORKER_MARKER)

            if marker_count != 1:
                raise GateError(EXIT_POLICY, "report_marker_duplicated",
                                f"Marker count != 1 (got {marker_count})")

            if block_count != 1:
                raise GateError(EXIT_POLICY, "report_json_block_duplicated",
                                f"JSON block count != 1 (got {block_count})")

            if report_json is None:
                raise GateError(EXIT_POLICY, "report_malformed_current_head",
                                "Worker report JSON is malformed")

            if report_json.get("kind") != "worker_report":
                raise GateError(EXIT_POLICY, "report_malformed_current_head",
                                "Worker report kind mismatch")

            head_sha_from_report = report_json.get("head_sha")

            if head_sha_from_report == self.expected_head:
                worker_reports_current.append({"comment": c, "report": report_json})
            else:
                worker_reports_historical.append({"comment": c, "report": report_json})

        # Check reviews for misplaced Worker reports
        for r in self.reviews:
            body = r.get("body", "") or ""
            if WORKER_MARKER in body:
                marker_in_review = True
                break

        if len(worker_reports_current) > 1:
            raise GateError(EXIT_POLICY, "duplicate_current_head_reports",
                            "Multiple worker reports for current HEAD")

        if len(worker_reports_current) == 0:
            if marker_in_review:
                raise GateError(EXIT_POLICY, "report_not_top_level",
                                "Worker report found in PR review, not top-level comment")
            raise GateError(EXIT_POLICY, "report_missing",
                            "No worker report found for current HEAD")

        entry = worker_reports_current[0]
        report = entry["report"]
        comment = entry["comment"]

        # Schema validation
        try:
            schema = load_schema(WORKER_SCHEMA_PATH)
            validator = SchemaValidator()
            if not validator.validate(report, schema, WORKER_SCHEMA_PATH):
                raise GateError(EXIT_POLICY, "report_extra_property",
                                "Worker report does not match schema")
        except GateError:
            raise

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

        workstream = report.get("workstream", "")
        if workstream != "U1R18-R7-FIX1":
            raise GateError(EXIT_POLICY, "report_workstream_mismatch",
                            f"Report workstream != U1R18-R7-FIX1 (got {workstream})")

        if not report.get("stop"):
            raise GateError(EXIT_POLICY, "report_stop_false",
                            "Report stop != true")

        if report.get("next_workstream_started"):
            raise GateError(EXIT_POLICY, "report_next_workstream_started",
                            "Report next_workstream_started == true")

        for field in ["ready_performed", "merge_performed", "release_performed"]:
            if report.get(field):
                raise GateError(EXIT_POLICY, "report_unsafe_action",
                                f"Report {field} == true")

        # Core CI jobs validation
        ci_jobs = report.get("core_ci_jobs", [])
        seen_jobs = set()
        for job in ci_jobs:
            if not isinstance(job, str):
                raise GateError(EXIT_POLICY, "report_invalid_array_item",
                                "core_ci_jobs contains non-string item")
            if job in seen_jobs:
                raise GateError(EXIT_POLICY, "report_duplicate_ci_jobs",
                                f"Duplicate CI job in report: {job}")
            seen_jobs.add(job)

        required_jobs = set(self.policy.get("core_ci", {}).get("required_jobs", []))
        report_jobs = set(ci_jobs)
        if not required_jobs.issubset(report_jobs):
            raise GateError(EXIT_POLICY, "report_ci_jobs_missing",
                            "Worker report missing required CI jobs")

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

        # edited_at must be preserved (not edited after posting)
        updated_at = comment.get("updated_at")
        if updated_at and updated_at != created_at:
            raise GateError(EXIT_POLICY, "report_edited_after_review",
                            "Worker report was edited after initial creation")

        self.worker_report = report
        self.worker_report_comment = comment

    # === CI run validation ===

    def _validate_ci_run(self):
        run_id = self.worker_report.get("core_ci_run_id")
        if run_id is None or run_id == 0:
            raise GateError(EXIT_POLICY, "ci_run_missing",
                            "Worker report core_ci_run_id is 0 or missing")

        runs = self.client.get_workflow_runs(self.expected_head)
        if not isinstance(runs, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Workflow runs data is not a list")

        matching_runs = [r for r in runs if r.get("id") == run_id]
        if len(matching_runs) == 0:
            raise GateError(EXIT_POLICY, "ci_run_missing",
                            f"CI run {run_id} not found for head {self.expected_head}")

        run = matching_runs[0]

        if run.get("head_sha") != self.expected_head:
            raise GateError(EXIT_POLICY, "ci_run_wrong_head",
                            "CI run head_sha != expected head")

        workflow_name = run.get("name", "")
        if workflow_name != "CI":
            raise GateError(EXIT_POLICY, "ci_run_wrong_workflow",
                            f"CI run workflow name is '{workflow_name}', expected 'CI'")

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
        job_names_seen = {}

        for required in required_jobs:
            matches = [j for j in jobs if j.get("name") == required]
            if len(matches) == 0:
                raise GateError(EXIT_POLICY, "ci_job_missing",
                                f"Required job '{required}' not found in CI run")
            if len(matches) > 1:
                raise GateError(EXIT_POLICY, "ci_job_duplicate",
                                f"Duplicate required job '{required}' in CI run")

            job = matches[0]
            conclusion = job.get("conclusion", "")

            if conclusion == "skipped":
                raise GateError(EXIT_POLICY, "ci_job_failed",
                                f"Required job '{required}' was skipped")
            if conclusion == "cancelled":
                raise GateError(EXIT_POLICY, "ci_job_failed",
                                f"Required job '{required}' was cancelled")
            if conclusion != "success":
                raise GateError(EXIT_POLICY, "ci_job_failed",
                                f"Required job '{required}' conclusion is '{conclusion}'")

        # Also check gate_advance_run_id if present
        advance_run_id = self.worker_report.get("gate_advance_run_id")
        if advance_run_id and advance_run_id > 0:
            advance_run = self.client.get_workflow_run_by_id(advance_run_id)
            if advance_run is None:
                raise GateError(EXIT_POLICY, "ci_run_missing",
                                f"Gate advance run {advance_run_id} not found")
            if advance_run.get("status") != "completed":
                raise GateError(EXIT_POLICY, "ci_run_incomplete",
                                "Gate advance run not completed")
            if advance_run.get("conclusion") != "success":
                raise GateError(EXIT_POLICY, "ci_run_not_success",
                                "Gate advance run conclusion != success")

    # === Controller review validation (review phase) ===

    def _validate_controller_review(self):
        reviews = self.reviews or self.client.get_reviews(self.pr_number)
        if not isinstance(reviews, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Reviews data is not a list")

        # Collect all controller reviews for the HEAD
        controller_reviews = []
        for r in reviews:
            if not isinstance(r, dict):
                continue
            if r.get("commit_id") != self.expected_head:
                continue

            body = r.get("body", "") or ""
            marker_count = body.count(CONTROLLER_MARKER)
            if marker_count == 0:
                continue
            if marker_count > 1:
                raise GateError(EXIT_POLICY, "controller_marker_duplicated_in_body",
                                "Controller marker duplicated in review body")

            json_data, _, block_count = parse_json_block(body, CONTROLLER_MARKER)
            if block_count != 1:
                raise GateError(EXIT_POLICY, "controller_json_blocks_duplicated",
                                "JSON blocks duplicated in review body")

            if json_data is None:
                raise GateError(EXIT_POLICY, "controller_review_missing",
                                "Controller review has marker but no valid JSON")

            if json_data.get("kind") != "controller_review":
                raise GateError(EXIT_POLICY, "controller_review_missing",
                                "Controller review kind mismatch")

            # Check for inline comments (not PR reviews)
            if "commit_id" not in r:
                raise GateError(EXIT_POLICY, "controller_review_not_pr_review",
                                "Controller review is not a PR review (missing commit_id)")

            if json_data.get("head_sha") != self.expected_head:
                raise GateError(EXIT_POLICY, "controller_json_head_mismatch",
                                "Controller JSON head_sha != expected head")

            quarantined = set(self.policy.get("quarantined_review_ids", []))
            if r.get("id") in quarantined:
                raise GateError(EXIT_POLICY, "quarantined_self_review_rejected",
                                "Controller review is quarantined")

            state = r.get("state", "")
            submitted_at_str = r.get("submitted_at")

            if state == "DISMISSED":
                controller_reviews.append({"review": r, "data": json_data,
                                           "valid": False, "reason": "dismissed",
                                           "submitted_at": submitted_at_str})
                continue

            if state == "CHANGES_REQUESTED":
                controller_reviews.append({"review": r, "data": json_data,
                                           "valid": False, "reason": "changes_requested",
                                           "submitted_at": submitted_at_str})
                continue

            if state not in ("COMMENTED", "APPROVED"):
                continue

            decision = json_data.get("decision")
            if decision == "rejected":
                controller_reviews.append({"review": r, "data": json_data,
                                           "valid": False, "reason": "rejected",
                                           "submitted_at": submitted_at_str})
                continue

            if decision != "accepted":
                continue

            # Validate all accepted fields
            errors = self._validate_controller_json(json_data)
            if errors:
                controller_reviews.append({"review": r, "data": json_data,
                                           "valid": False, "reason": errors[0],
                                           "submitted_at": submitted_at_str})
                continue

            # Check submitted after worker report
            worker_updated = self.worker_report_comment.get("updated_at")
            if worker_updated:
                worker_time = parse_iso_datetime(worker_updated)
                review_time = parse_iso_datetime(submitted_at_str)
                if review_time < worker_time:
                    controller_reviews.append({"review": r, "data": json_data,
                                               "valid": False, "reason": "before_report",
                                               "submitted_at": submitted_at_str})
                    continue

            controller_reviews.append({"review": r, "data": json_data,
                                       "valid": True, "submitted_at": submitted_at_str})

        if not controller_reviews:
            for r in reviews:
                body = r.get("body", "") or ""
                if CONTROLLER_MARKER in body and r.get("commit_id") == self.expected_head:
                    raise GateError(EXIT_POLICY, "controller_review_missing",
                                    "Controller review has marker but fails validation")
            raise GateError(EXIT_POLICY, "controller_review_missing",
                            "No controller review found for HEAD")

        controller_reviews.sort(
            key=lambda x: x.get("submitted_at") or "0000-01-01T00:00:00Z"
        )
        latest = controller_reviews[-1]

        if not latest["valid"]:
            reason = latest["reason"]
            REASON_MAP = {
                "dismissed": "selected_dismissed",
                "changes_requested": "selected_changes_requested",
                "rejected": "latest_rejected_overrides_old_green",
                "before_report": "review_before_report",
                "quarantined": "quarantined_self_review_rejected",
                "after_child": "parent_review_after_child",
            }
            guard = REASON_MAP.get(reason, reason)
            raise GateError(EXIT_POLICY, guard,
                            f"Latest controller review invalid: {reason}")

        # Double-check: also verify all the specific controller review fields
        # by running the shared validator again
        data = latest["data"]
        if data.get("decision") != "accepted":
            raise GateError(EXIT_POLICY, "controller_review_not_accepted",
                            "Controller review decision != accepted")
        if not data.get("classification", "").startswith("GREEN_"):
            raise GateError(EXIT_POLICY, "controller_classification_not_green",
                            "Classification does not start with GREEN_")
        if not data.get("review_complete"):
            raise GateError(EXIT_POLICY, "controller_review_complete_false",
                            "review_complete != true")
        if not data.get("nx_required_for_next_workstream"):
            raise GateError(EXIT_POLICY, "controller_nx_required_false",
                            "nx_required_for_next_workstream != true")
        if data.get("ready_authorized"):
            raise GateError(EXIT_POLICY, "controller_ready_true",
                            "ready_authorized == true")
        if data.get("merge_authorized"):
            raise GateError(EXIT_POLICY, "controller_merge_true",
                            "merge_authorized == true")
        if data.get("release_authorized"):
            raise GateError(EXIT_POLICY, "controller_release_true",
                            "release_authorized == true")

    # === Output ===

    def _output_success(self):
        if self.phase == "advance":
            result = {
                "state": "CURRENT_WORKSTREAM_ACTIVE",
                "parent_authority": self.parent_authority,
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
            raise GateError(EXIT_INFRA, "unknown_phase",
                            f"Unknown phase: {self.phase}")

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
        if e.message:
            result["message"] = e.message
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
