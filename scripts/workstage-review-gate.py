#!/usr/bin/env python3
"""
  Workstream Review Gate — U1R18-R7-FIX3

  Enforces sequential workstream advancement on a single PR.
  Verifies that each commit has a preceding controller review before
  the next workstream can start.  FIX2 added trusted submission receipt
  binding: the submission phase outputs its own GITHUB_RUN_ID as the
  trusted receipt, which is then validated via GitHub API in review and
  future-child-advance phases.  FIX3 wires the hosted submission lane:
  the workflow_dispatch entrypoint requires the exact worker report
  comment ID, publishes a canonical workflow-level run-name
  (display_title), and the submission phase fails closed when it is not
  running inside the hosted GitHub Actions context.  Dynamic run
  identity is verified against display_title (not run.name).

Usage (live mode):
  python3 scripts/workstage-review-gate.py \\
    --phase advance --pr-number 2 --expected-head <SHA>

Usage (fixture/offline mode):
  python3 scripts/workstage-review-gate.py \\
    --phase submission --pr-number 2 --expected-head <SHA> \\
    --fixtures scripts/workstage-review-gate-fixtures/green/submission

Usage (workflow semantic audit):
  python3 scripts/workstage-review-gate.py --check-workflow <workflow.yml>

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

try:
    import yaml
    HAS_YAML = True
except ImportError:  # pragma: no cover
    yaml = None
    HAS_YAML = False

EXIT_OK = 0
EXIT_POLICY = 1
EXIT_INFRA = 2

WORKER_MARKER = "<!-- macsteam-worker-report:v1 -->"
CONTROLLER_MARKER = "<!-- macsteam-controller-review:v1 -->"

WORKER_SCHEMA_PATH = "Contracts/workstream-report.schema.json"
CONTROLLER_SCHEMA_PATH = "Contracts/controller-review.schema.json"
POLICY_PATH_DEFAULT = ".github/workstage-review-gate-policy.json"

FIX3_WORKSTREAM = "U1R18-R7-FIX3"
FIX2_WORKSTREAM = "U1R18-R7-FIX2"
FIX1_WORKSTREAM = "U1R18-R7-FIX1"

WORKSTREAM_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

# Tier A: immutable safe envelope for repair-path authority.
# A changed file must satisfy the envelope AND the policy-declared scope.
SAFE_REPAIR_EXACT_PATHS = frozenset({
    ".github/workstage-review-gate-policy.json",
    "scripts/workstage-review-gate.py",
    "scripts/test-workstage-review-gate.sh",
    "scripts/u1r18-pr-truth.py",
    "scripts/test-u1r18-pr-truth.sh",
    # Tier A public-truth governance envelope: the accepted README/authority
    # manifest/schema and the designated canonical docs plus their audit tooling.
    # These are bounded exact paths, never a generic docs/ or Contracts/ glob.
    "README.md",
    "Contracts/public-product-truth.schema.json",
    "docs/public-product-truth.json",
    "docs/ARCHITECTURE.md",
    "docs/CLOVERPIT_U1.md",
    "docs/DISTRIBUTION_BOUNDARIES.md",
    "docs/GAME_RECIPE_CONTRACT.md",
    "docs/PREFIX_LIFECYCLE.md",
    "docs/RUNTIME_CONTRACT.md",
    "docs/SECURITY_BOUNDARIES.md",
    "docs/STEAM_BOUNDARY.md",
    "docs/ULTIMATE_ARCHITECTURE.md",
    "scripts/public-product-truth-audit.py",
    "scripts/test-public-product-truth-audit.sh",
})
SAFE_REPAIR_PATH_PREFIXES = (
    "scripts/workstage-review-gate-fixtures/",
    "scripts/u1r18-pr-truth-fixtures/",
    "scripts/public-product-truth-fixtures/",
)

WORKFLOW_PATH_DEFAULT = ".github/workflows/workstage-review-gate.yml"
WORKFLOW_NAME_DEFAULT = "Workstream Review Gate"

HOSTED_RUN_NAME_TEMPLATE = "MacSteam Gate / phase=submission / PR={pr} / HEAD={head} / REPORT={report}"

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

    def get_comment_by_id(self, comment_id):
        if self.fixtures_dir:
            return self._load("comment.json")
        return self._gh_object(f"issues/comments/{comment_id}")

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
            sub_runs_path = os.path.join(self.fixtures_dir, "submission-runs.json")
            is_submission_run = False
            if os.path.exists(sub_runs_path):
                data = self._load("submission-runs.json")
                runs = data.get("workflow_runs", []) if isinstance(data, dict) else data
                for r in runs:
                    if r.get("id") == run_id:
                        is_submission_run = True
                        break
            if is_submission_run:
                sub_jobs_path = os.path.join(self.fixtures_dir, "submission-jobs.json")
                if os.path.exists(sub_jobs_path):
                    data = self._load("submission-jobs.json")
                    jobs = data.get("jobs", []) if isinstance(data, dict) else data
                    return self._filter_jobs_by_run(jobs, run_id)
            data = self._load("jobs.json")
            jobs = data.get("jobs", []) if isinstance(data, dict) else data
            return self._filter_jobs_by_run(jobs, run_id)
        pages = self._gh_paginated_pages(f"actions/runs/{run_id}/jobs")
        return [job for page in pages for job in page.get("jobs", [])]

    @staticmethod
    def _filter_jobs_by_run(jobs, run_id):
        """Filter fixture jobs to those belonging to the requested run.

        The real GitHub API returns only the jobs for a single run, so the
        fixture dispatch must apply the same scoping when a shared jobs file
        contains jobs for multiple runs (e.g. parent + head submission runs).
        """
        if not isinstance(jobs, list):
            return jobs
        scoped = [j for j in jobs if isinstance(j, dict) and j.get("run_id") == run_id]
        if scoped:
            return scoped
        if any(isinstance(j, dict) and "run_id" in j for j in jobs):
            return []
        return jobs

    def get_workflow_run_by_id(self, run_id):
        if self.fixtures_dir:
            sub_runs_path = os.path.join(self.fixtures_dir, "submission-runs.json")
            if os.path.exists(sub_runs_path):
                data = self._load("submission-runs.json")
                runs = data.get("workflow_runs", []) if isinstance(data, dict) else data
                matches = [r for r in runs if isinstance(r, dict) and r.get("id") == run_id]
                if len(matches) > 1:
                    raise GateError(EXIT_INFRA, "submission_runs_duplicate_id",
                                    f"Duplicate submission run ID in fixtures: {run_id}")
                if matches:
                    return matches[0]
            data = self._load("runs.json")
            runs = data.get("workflow_runs", []) if isinstance(data, dict) else data
            matches = [r for r in runs if isinstance(r, dict) and r.get("id") == run_id]
            if len(matches) > 1:
                raise GateError(EXIT_INFRA, "submission_runs_duplicate_id",
                                f"Duplicate run ID in fixtures: {run_id}")
            if matches:
                return matches[0]
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
                 policy_path, max_items, worker_report_comment_id=None,
                 submission_run_id=None):
        self.phase = phase
        self.pr_number = pr_number
        self.expected_head = expected_head
        self.repo = repo
        self.fixtures_dir = fixtures_dir
        self.policy_path = policy_path
        self.max_items = max_items
        self.worker_report_comment_id = worker_report_comment_id
        self._submission_run_id_input = submission_run_id

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
        self._comments_loaded = False
        self._submission_run_id_validated = None
        self._review_receipt_validated = False

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
                self._validate_hosted_submission_context()
                self._validate_worker_report_submission()
                self._validate_ci_run()
                self._validate_advance_run()
            elif self.phase == "review":
                self._validate_review_report_id_input()
                self._validate_worker_report_replay()
                self._validate_ci_run()
                self._validate_controller_review()
                self._validate_review_report_id_binding()
                self._validate_submission_receipt()
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
        # Two-tier repair authority: first validate the policy-declared scope.
        self._validate_repair_scope(repair)

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
        review_state = review.get("state", "") or ""
        if review_state not in ("COMMENTED", "CHANGES_REQUESTED"):
            raise GateError(EXIT_POLICY, "repair_wrong_review_state",
                            "Repair review state must be COMMENTED or CHANGES_REQUESTED")

        marker_count = review_body.count(CONTROLLER_MARKER)
        if marker_count != 1:
            raise GateError(EXIT_POLICY, "repair_marker_duplicated",
                            f"Repair review controller marker count != 1 (got {marker_count})")

        json_data, _, block_count = parse_json_block(review_body, CONTROLLER_MARKER)
        if block_count != 1:
            raise GateError(EXIT_POLICY, "repair_json_blocks_duplicated",
                            f"Repair review JSON block count != 1 (got {block_count})")
        if json_data is None:
            raise GateError(EXIT_POLICY, "repair_malformed_json",
                            "Repair review controller JSON is malformed")
        if not validate_document(json_data, CONTROLLER_SCHEMA_PATH, CONTROLLER_SCHEMA_PATH):
            raise GateError(EXIT_POLICY, "repair_schema_invalid",
                            "Repair review controller JSON fails schema validation")

        if json_data.get("kind") != "controller_review":
            raise GateError(EXIT_POLICY, "repair_wrong_kind",
                            "Repair review JSON kind != controller_review")
        if json_data.get("head_sha") != parent_sha:
            raise GateError(EXIT_POLICY, "repair_json_head_mismatch",
                            "Repair review JSON head_sha != policy parent_sha")
        if json_data.get("decision") != "rejected":
            raise GateError(EXIT_POLICY, "repair_wrong_decision",
                            "Repair review decision != rejected")
        if json_data.get("classification") != classification:
            raise GateError(EXIT_POLICY, "repair_wrong_classification",
                            "Repair review JSON classification != policy classification")
        if json_data.get("review_complete") is not True:
            raise GateError(EXIT_POLICY, "repair_review_incomplete",
                            "Repair review review_complete != true")
        if json_data.get("nx_required_for_next_workstream") is not True:
            raise GateError(EXIT_POLICY, "repair_nx_required_false",
                            "Repair review nx_required_for_next_workstream != true")
        for flag in ("ready_authorized", "merge_authorized", "release_authorized"):
            if json_data.get(flag):
                raise GateError(EXIT_POLICY, "repair_unsafe_authorization",
                                f"Repair review {flag} == true")

        if not self._check_review_before_child(review):
            raise GateError(EXIT_POLICY, "repair_review_after_child",
                            "Repair review timestamp does not precede child commit")

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

        # Changed paths validation (two-tier: safe envelope AND declared scope)
        files = self._get_changed_files()
        for filepath in files:
            if not self._repair_path_allowed(filepath):
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

    # === Two-tier repair-path authority ===
    #
    # Tier A: immutable safe envelope (hardcoded). A repair child may only touch
    # paths that live inside the safe envelope.
    # Tier B: the current policy repair_authorization declares the permitted
    # scope (allowed_exact_paths / allowed_path_prefixes). A changed path must
    # satisfy BOTH tiers.
    @staticmethod
    def _in_safe_envelope(filepath):
        if filepath in SAFE_REPAIR_EXACT_PATHS:
            return True
        for prefix in SAFE_REPAIR_PATH_PREFIXES:
            if filepath.startswith(prefix):
                return True
        return False

    @staticmethod
    def _validate_repair_path_entry(entry, is_prefix):
        if not isinstance(entry, str) or not entry:
            return False
        if is_prefix and not entry.endswith("/"):
            return False
        if entry.startswith("/"):
            return False
        if entry.startswith("./"):
            return False
        if "\\" in entry:
            return False
        if "//" in entry:
            return False
        if any(ord(c) < 32 for c in entry):
            return False
        segments = entry.rstrip("/").split("/")
        for seg in segments:
            if seg in ("", ".", ".."):
                return False
        return True

    def _validate_repair_scope(self, repair):
        exact = repair.get("allowed_exact_paths")
        prefixes = repair.get("allowed_path_prefixes")

        if exact is None or prefixes is None:
            raise GateError(EXIT_INFRA, "repair_scope_invalid",
                            "Repair scope fields missing")
        if not isinstance(exact, list) or not isinstance(prefixes, list):
            raise GateError(EXIT_INFRA, "repair_scope_invalid",
                            "Repair scope fields must be arrays")
        if not exact or not prefixes:
            raise GateError(EXIT_INFRA, "repair_scope_invalid",
                            "Repair scope arrays must be non-empty")

        seen = set()
        for entry in exact:
            if not self._validate_repair_path_entry(entry, is_prefix=False):
                raise GateError(EXIT_INFRA, "repair_scope_invalid",
                                f"Invalid repair exact path: {entry!r}")
            if entry in seen:
                raise GateError(EXIT_INFRA, "repair_scope_invalid",
                                f"Duplicate repair exact path: {entry!r}")
            seen.add(entry)
            if not self._in_safe_envelope(entry):
                raise GateError(EXIT_POLICY, "repair_scope_outside_safe_envelope",
                                f"Repair exact path outside safe envelope: {entry!r}")

        for entry in prefixes:
            if not self._validate_repair_path_entry(entry, is_prefix=True):
                raise GateError(EXIT_INFRA, "repair_scope_invalid",
                                f"Invalid repair path prefix: {entry!r}")
            if entry in seen:
                raise GateError(EXIT_INFRA, "repair_scope_invalid",
                                f"Duplicate repair path prefix: {entry!r}")
            seen.add(entry)
            if not self._in_safe_envelope(entry):
                raise GateError(EXIT_POLICY, "repair_scope_outside_safe_envelope",
                                f"Repair path prefix outside safe envelope: {entry!r}")

    def _repair_path_allowed(self, filepath):
        if not self._in_safe_envelope(filepath):
            return False
        repair = self.policy.get("repair_authorization", {})
        exact = repair.get("allowed_exact_paths", [])
        prefixes = repair.get("allowed_path_prefixes", [])
        if filepath in exact:
            return True
        for prefix in prefixes:
            if filepath.startswith(prefix):
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

        # FIX2: if parent controller review has submission receipt fields,
        # validate the submission run receipt (future-child advance §9)
        latest_review = marker_reviews[-1]["review"]
        body = latest_review.get("body", "") or ""
        latest_json, _, _ = parse_json_block(body, CONTROLLER_MARKER)
        if isinstance(latest_json, dict):
            sub_id = latest_json.get("submission_run_id")
            wr_cid = latest_json.get("worker_report_comment_id")
            if isinstance(sub_id, int) and not isinstance(sub_id, bool) and sub_id >= 1:
                self._validate_submission_run_receipt(sub_id, wr_cid, target_head=self.parent_sha)

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

        # FIX2: require submission receipt fields
        wr_cid = data.get("worker_report_comment_id")
        if not isinstance(wr_cid, int) or isinstance(wr_cid, bool) or wr_cid < 1:
            errors.append("controller_worker_report_comment_id_invalid")

        sub_rid = data.get("submission_run_id")
        if not isinstance(sub_rid, int) or isinstance(sub_rid, bool) or sub_rid < 1:
            errors.append("controller_submission_run_id_invalid")

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

    # === Hosted submission context (FIX3 fail-closed) ===

    def _validate_hosted_submission_context(self):
        """FIX3 §6: fail closed unless running in the hosted submission lane.

        A locally-executed gate script must NEVER emit a hosted submission
        receipt.  Missing, empty, zero, negative, non-integer run IDs, a
        run attempt other than 1, a non-workflow_dispatch event, a
        repository mismatch, or a missing hosted context all exit 2 with a
        REJECTED state.
        """
        if os.environ.get("GITHUB_ACTIONS", "") != "true":
            raise GateError(EXIT_INFRA, "hosted_submission_context_missing",
                            "Submission gate is not running inside GitHub Actions")
        if os.environ.get("GITHUB_EVENT_NAME", "") != "workflow_dispatch":
            raise GateError(EXIT_INFRA, "hosted_submission_event_invalid",
                            f"Submission gate event is not workflow_dispatch: "
                            f"{os.environ.get('GITHUB_EVENT_NAME')}")
        repo = os.environ.get("GITHUB_REPOSITORY", "")
        if repo != self.repo:
            raise GateError(EXIT_INFRA, "hosted_submission_repository_mismatch",
                            f"Submission gate repository mismatch: {repo} != {self.repo}")
        run_id = os.environ.get("GITHUB_RUN_ID", "")
        if not re.fullmatch(r"[1-9][0-9]*", run_id):
            raise GateError(EXIT_INFRA, "hosted_submission_run_id_invalid",
                            f"Submission GITHUB_RUN_ID invalid: {run_id!r}")
        if os.environ.get("GITHUB_RUN_ATTEMPT", "") != "1":
            raise GateError(EXIT_INFRA, "hosted_submission_attempt_invalid",
                            f"Submission GITHUB_RUN_ATTEMPT != 1: "
                            f"{os.environ.get('GITHUB_RUN_ATTEMPT')!r}")
        if os.environ.get("GITHUB_WORKFLOW", "") != WORKFLOW_NAME_DEFAULT:
            raise GateError(EXIT_INFRA, "hosted_submission_context_missing",
                            "Submission gate workflow name is not Workstream Review Gate")
        if not re.fullmatch(r"[a-f0-9]{40}", self.expected_head):
            raise GateError(EXIT_INFRA, "hosted_submission_context_missing",
                            "Submission expected_head is not a 40-char SHA")
        if self.worker_report_comment_id is None or self.worker_report_comment_id < 1:
            raise GateError(EXIT_INFRA, "hosted_submission_context_missing",
                            "Submission gate missing a positive worker report comment ID")

    # === Worker report validation ===

    def _head_workstream(self):
        message = self.commit_head.get("commit", {}).get("message", "")
        if not isinstance(message, str) or not message:
            raise GateError(
                EXIT_INFRA,
                "head_commit_message_missing",
                "HEAD commit message is missing",
            )

        matches = re.findall(
            r"^Workstream:\s*(.+?)\s*$",
            message,
            re.MULTILINE,
        )

        if len(matches) == 0:
            raise GateError(
                EXIT_POLICY,
                "head_workstream_trailer_missing",
                "HEAD commit has no Workstream trailer",
            )

        if len(matches) != 1:
            raise GateError(
                EXIT_POLICY,
                "head_workstream_trailer_duplicated",
                "HEAD commit must contain exactly one Workstream trailer",
            )

        workstream = matches[0].strip()

        if not WORKSTREAM_PATTERN.fullmatch(workstream):
            raise GateError(
                EXIT_POLICY,
                "head_workstream_trailer_invalid",
                "HEAD Workstream trailer is invalid",
            )

        return workstream

    def _validate_worker_report_fields(self, report, comment):
        """Shared field validation for worker reports (FIX2)."""
        schema = load_schema(WORKER_SCHEMA_PATH)
        validator = SchemaValidator()
        if not validator.validate(report, schema, WORKER_SCHEMA_PATH):
            raise GateError(EXIT_POLICY, "report_extra_property",
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

        workstream = report.get("workstream", "")
        expected_ws = self._head_workstream()
        if workstream != expected_ws:
            raise GateError(EXIT_POLICY, "report_workstream_mismatch",
                            f"Report workstream != HEAD trailer {expected_ws} (got {workstream})")

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

        # gate_submission_run_id must be null for pre-submission worker report
        if report.get("gate_submission_run_id") is not None:
            raise GateError(EXIT_POLICY, "report_submission_run_not_null",
                            "Worker report gate_submission_run_id must be null (pre-submission)")

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

    def _validate_worker_report_submission(self):
        """FIX2 submission: fetch worker report by comment ID."""
        if self.worker_report_comment_id is None:
            raise GateError(EXIT_INFRA, "worker_report_comment_id_required",
                            "Worker report comment ID is required for submission phase")

        comment = self.client.get_comment_by_id(self.worker_report_comment_id)
        if not isinstance(comment, dict):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Comment data is not an object")

        body = comment.get("body", "") or ""

        if comment.get("in_reply_to_id"):
            raise GateError(EXIT_POLICY, "report_reply",
                            "Worker report is a reply to another comment")
        if comment.get("path") or comment.get("position"):
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

        self._validate_worker_report_fields(report_json, comment)

        self.worker_report = report_json
        self.worker_report_comment = comment

        # FIX2 replay protection: scan the full comment list for the current
        # HEAD worker report. This detects duplicated reports, conflicting
        # historical reports, and reports posted in PR reviews instead of
        # top-level comments.
        self._validate_worker_report_replay()

    def _head_commit_datetime(self):
        """HEAD commit committer datetime. Fail closed if missing/malformed."""
        commit_date_str = self.commit_head.get("commit", {}).get("committer", {}).get("date")
        if not commit_date_str:
            raise GateError(EXIT_INFRA, "timestamp_malformed",
                            "HEAD commit has no committer date")
        return parse_iso_datetime(commit_date_str)

    def _comment_datetime(self, comment):
        """Comment created_at datetime. Fail-closed if missing/malformed."""
        created_at = comment.get("created_at")
        if not created_at:
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Comment has no created_at timestamp")
        return parse_iso_datetime(created_at)

    def _validate_worker_report_replay(self):
        """FIX1 review: scan comments for current HEAD worker report.

        Replay isolation is based on the HEAD commit timestamp boundary:
        marker-bearing comments created strictly before the HEAD commit are
        historical objects and are excluded from current-HEAD uniqueness, so a
        historical malformed report can never poison a later HEAD. Comments at
        or after the HEAD commit are current-window objects and are validated
        fully fail-closed.
        """
        self.comments = self.client.get_comments(self.pr_number)
        if not isinstance(self.comments, list):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Comments data is not a list")

        if not self._reviews_loaded:
            self._load_reviews()

        commit_date = self._head_commit_datetime()
        worker_reports_current = []
        marker_in_review = False

        for c in self.comments:
            body = c.get("body", "") or ""
            if WORKER_MARKER not in body:
                continue

            created_at = self._comment_datetime(c)

            # Historical marker object: it existed before this HEAD. It is a
            # separate historical object and must not poison a later window,
            # regardless of whether its marker/JSON is well-formed.
            if created_at < commit_date:
                continue

            # Current-window marker objects are strict / fail-closed.
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

            if report_json.get("head_sha") == self.expected_head:
                worker_reports_current.append({"comment": c, "report": report_json})

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
        self._validate_worker_report_fields(entry["report"], entry["comment"])

        self.worker_report = entry["report"]
        self.worker_report_comment = entry["comment"]

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

    def _validate_advance_run(self):
        """FIX2: validate the gate_advance_run_id from the worker report."""
        advance_run_id = self.worker_report.get("gate_advance_run_id")
        if advance_run_id is None or advance_run_id == 0:
            raise GateError(EXIT_POLICY, "advance_run_missing",
                            "Worker report gate_advance_run_id is 0 or missing")

        advance_run = self.client.get_workflow_run_by_id(advance_run_id)
        if advance_run is None:
            raise GateError(EXIT_POLICY, "advance_run_missing",
                            f"Advance run {advance_run_id} not found")
        if not isinstance(advance_run, dict):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Advance run data is not an object")

        if advance_run.get("head_sha") != self.expected_head:
            raise GateError(EXIT_POLICY, "advance_run_wrong_head",
                            "Advance run head_sha != expected head")

        # The gate workflow declares a `run-name`, so the GitHub API reports the
        # run's `name` as the interpolated run-name, not the workflow's `name:`.
        # The deterministic static identity of a gate-workflow run is its
        # canonical path.
        run_path = advance_run.get("path", "") or advance_run.get("workflow_path", "") or ""
        run_path_norm = run_path.split("@", 1)[0]
        if run_path_norm != WORKFLOW_PATH_DEFAULT:
            raise GateError(EXIT_POLICY, "advance_run_wrong_workflow",
                            f"Advance run workflow path is '{run_path_norm}', "
                            f"expected '{WORKFLOW_PATH_DEFAULT}'")

        if advance_run.get("status") != "completed":
            raise GateError(EXIT_POLICY, "advance_run_incomplete",
                            "Advance run not completed")

        if advance_run.get("conclusion") != "success":
            raise GateError(EXIT_POLICY, "advance_run_not_success",
                            "Advance run conclusion != success")

        run_attempt = advance_run.get("run_attempt")
        if run_attempt is not None and run_attempt != 1:
            raise GateError(EXIT_POLICY, "advance_run_attempt_gt_one",
                            f"Advance run attempt > 1 ({run_attempt})")

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

        self._controller_review_data = data
        self._controller_review_submitted_at = latest.get("submitted_at")

    # === Submission receipt validation (FIX2) ===

    def _validate_review_report_id_input(self):
        """FIX3 §5.6: the review dispatch must carry the exact worker report
        comment ID as a CLI input (never left empty or unused)."""
        if self.worker_report_comment_id is None:
            raise GateError(EXIT_INFRA, "worker_report_comment_id_required",
                            "Worker report comment ID is required for review phase")
        if self.worker_report_comment_id < 1:
            raise GateError(EXIT_POLICY, "worker_report_comment_id_invalid",
                            "Worker report comment ID must be a positive integer")

    def _validate_review_report_id_binding(self):
        """FIX3 §5.6: dispatch input ID == canonical current-head Worker report
        ID == controller review JSON worker_report_comment_id. The value must be
        used, never merely accepted."""
        if self.worker_report_comment is None:
            raise GateError(EXIT_POLICY, "review_report_id_missing",
                            "Review phase has no canonical worker report comment")
        canonical_id = self.worker_report_comment.get("id")
        if canonical_id is None or not isinstance(canonical_id, int) or canonical_id < 1:
            raise GateError(EXIT_POLICY, "review_report_id_missing",
                            "Review phase canonical worker report comment ID invalid")
        if self.worker_report_comment_id != canonical_id:
            raise GateError(EXIT_POLICY, "review_report_id_mismatch",
                            f"Dispatch report comment ID {self.worker_report_comment_id} "
                            f"!= canonical report ID {canonical_id}")
        data = getattr(self, '_controller_review_data', None)
        controller_id = data.get("worker_report_comment_id") if isinstance(data, dict) else None
        if controller_id != self.worker_report_comment_id:
            raise GateError(EXIT_POLICY, "review_report_id_mismatch",
                            f"Controller review report comment ID {controller_id} "
                            f"!= dispatch report comment ID {self.worker_report_comment_id}")

    def _validate_submission_receipt(self):
        """FIX2 review phase: validate submission workflow run receipt via GitHub API."""
        data = getattr(self, '_controller_review_data', None)
        if data is None:
            raise GateError(EXIT_POLICY, "controller_review_missing",
                            "No accepted controller review for HEAD")

        review_submit_time = getattr(self, '_controller_review_submitted_at', None)
        review_time = parse_iso_datetime(review_submit_time) if review_submit_time else None

        self._validate_submission_run_receipt(
            data.get("submission_run_id"),
            data.get("worker_report_comment_id"),
            target_head=self.expected_head,
            worker_report_comment=self.worker_report_comment,
            review_submit_time=review_time,
        )
        self._review_receipt_validated = True

    def _validate_submission_run_receipt(self, submission_run_id, worker_report_comment_id,
                                         target_head=None, worker_report_comment=None,
                                         review_submit_time=None):
        """Validate a submission workflow run against the FIX2 contract (§8).
        target_head: the head_sha the submission run should be for (HEAD or parent).
        worker_report_comment: the worker report comment (for chronology check)."""
        if target_head is None:
            target_head = self.expected_head

        if not isinstance(submission_run_id, int) or isinstance(submission_run_id, bool) or submission_run_id < 1:
            raise GateError(EXIT_POLICY, "submission_run_id_invalid",
                            "submission_run_id must be a positive integer")

        if worker_report_comment_id is None:
            raise GateError(EXIT_POLICY, "submission_run_wrong_report_id",
                            "worker_report_comment_id is required for submission run validation")

        run = self.client.get_workflow_run_by_id(submission_run_id)
        if run is None:
            raise GateError(EXIT_POLICY, "submission_run_missing",
                            f"Submission run {submission_run_id} not found")
        if not isinstance(run, dict):
            raise GateError(EXIT_INFRA, "object_unparseable",
                            "Submission run data is not an object")

        # §8.1 Static workflow identity.
        # The gate workflow declares a `run-name`, so the GitHub API reports the
        # run's `name` as the interpolated run-name rather than the workflow's
        # `name:`. The deterministic static identity of a gate-workflow run is its
        # canonical path (guarded by receipt_wrong_workflow_path). The dynamic
        # identity is validated separately from the exact `display_title`.
        repo_full = self.repo
        run_path = run.get("path", "") or run.get("workflow_path", "") or ""
        run_path_norm = run_path.split("@", 1)[0]
        if run_path_norm != WORKFLOW_PATH_DEFAULT:
            raise GateError(EXIT_POLICY, "receipt_wrong_workflow_path",
                            f"Submission run workflow path is '{run_path_norm}', "
                            f"expected '{WORKFLOW_PATH_DEFAULT}'")
        if run.get("repository", {}).get("full_name") != repo_full:
            raise GateError(EXIT_POLICY, "submission_run_wrong_repository",
                            "Submission run repository mismatch")
        if run.get("head_sha") != target_head:
            raise GateError(EXIT_POLICY, "submission_run_wrong_head",
                            "Submission run head_sha != expected head")
        expected_branch = self.policy.get("branch", "")
        if run.get("head_branch") != expected_branch:
            raise GateError(EXIT_POLICY, "submission_run_wrong_branch",
                            "Submission run head_branch != expected branch")
        if run.get("event") != "workflow_dispatch":
            raise GateError(EXIT_POLICY, "submission_run_wrong_event",
                            "Submission run event != workflow_dispatch")

        # §8.2 Dynamic run identity — display_title only.
        # GitHub API v3 exposes the workflow-level run-name as display_title;
        # run.name is the static workflow name and must never be used as the
        # dynamic receipt identity.
        expected_title = HOSTED_RUN_NAME_TEMPLATE.format(
            pr=self.pr_number, head=target_head, report=worker_report_comment_id)
        display_title = run.get("display_title", "")
        if display_title != expected_title:
            self._raise_display_title_mismatch(display_title, expected_title,
                                               target_head, worker_report_comment_id)

        if str(run.get("id")) != str(submission_run_id):
            raise GateError(EXIT_POLICY, "submission_run_id_mismatch",
                            "Submission run ID mismatch")

        if run.get("status") != "completed":
            raise GateError(EXIT_POLICY, "submission_run_incomplete",
                            "Submission run not completed")
        if run.get("conclusion") != "success":
            raise GateError(EXIT_POLICY, "submission_run_failed",
                            "Submission run conclusion != success")

        run_attempt = run.get("run_attempt")
        if run_attempt is not None and run_attempt != 1:
            raise GateError(EXIT_POLICY, "submission_run_attempt_gt_one",
                            f"Submission run attempt > 1 ({run_attempt})")

        # §8.3 Job identity — exactly one completed/success Submission Gate
        jobs = self.client.get_workflow_jobs(submission_run_id)
        if not isinstance(jobs, list):
            raise GateError(EXIT_INFRA, "workflow_jobs_malformed",
                            "Submission run jobs data is not a list")

        gate_jobs = []
        job_names = set()
        for j in jobs:
            if not isinstance(j, dict):
                raise GateError(EXIT_INFRA, "pagination_page_type_invalid",
                                "A job item is not an object")
            jid = j.get("id")
            if not isinstance(jid, int) or isinstance(jid, bool):
                raise GateError(EXIT_INFRA, "submission_job_id_non_integer",
                                "A submission job has a non-integer id")
            jname = j.get("name", "")
            job_names.add(jname)
            if jname == "Submission Gate":
                gate_jobs.append(j)

        if len(gate_jobs) == 0:
            if job_names & {"Manual Gate", "Review Gate", "Advance Gate"}:
                raise GateError(EXIT_POLICY, "receipt_submission_job_wrong_name",
                                "Submission run has a gate job with a non-canonical name")
            raise GateError(EXIT_POLICY, "receipt_submission_job_missing",
                            "Submission gate job not found")
        if len(gate_jobs) > 1:
            raise GateError(EXIT_POLICY, "receipt_submission_job_duplicate",
                            "Multiple submission gate jobs found")

        gate_job = gate_jobs[0]
        if gate_job.get("status") != "completed":
            raise GateError(EXIT_POLICY, "submission_gate_job_incomplete",
                            "Submission gate job not completed")
        conclusion = gate_job.get("conclusion")
        if conclusion in ("skipped", None):
            raise GateError(EXIT_POLICY, "submission_gate_job_skipped",
                            "Submission gate job was skipped")
        if conclusion == "cancelled":
            raise GateError(EXIT_POLICY, "submission_gate_job_cancelled",
                            "Submission gate job was cancelled")
        if conclusion != "success":
            raise GateError(EXIT_POLICY, "submission_gate_job_failed",
                            "Submission gate job conclusion != success")
        if gate_job.get("run_id", submission_run_id) != submission_run_id:
            raise GateError(EXIT_POLICY, "submission_run_id_mismatch",
                            "Submission gate job run_id mismatch")

        # §8.2 Chronology
        if worker_report_comment:
            created_at = worker_report_comment.get("created_at")
            if created_at:
                report_time = parse_iso_datetime(created_at)
                run_started = run.get("started_at") or run.get("created_at")
                if run_started:
                    run_start_time = parse_iso_datetime(run_started)
                    if report_time > run_start_time:
                        raise GateError(EXIT_POLICY, "report_created_after_submission_run",
                                        "Worker report created after submission run started")

        if review_submit_time:
            completed_at_str = run.get("completed_at")
            if completed_at_str:
                completed_at = parse_iso_datetime(completed_at_str)
                if completed_at > review_submit_time:
                    raise GateError(EXIT_POLICY, "submission_completed_after_controller_review",
                                    "Submission run completed after controller review")

        self._submission_run_id_validated = submission_run_id

    def _raise_display_title_mismatch(self, display_title, expected_title,
                                      target_head, worker_report_comment_id):
        """Raise the most specific display_title guard for a mismatch."""
        if not display_title:
            raise GateError(EXIT_POLICY, "receipt_display_title_missing",
                            "Submission run has no display_title")
        prefix = "MacSteam Gate / "
        if not display_title.startswith(prefix):
            raise GateError(EXIT_POLICY, "receipt_display_title_wrong_phase",
                            f"Submission display_title format mismatch: {display_title!r}")
        fields = {}
        for part in display_title[len(prefix):].split(" / "):
            if "=" in part:
                key, value = part.split("=", 1)
                fields[key.strip()] = value.strip()
        if fields.get("phase") != "submission":
            raise GateError(EXIT_POLICY, "receipt_display_title_wrong_phase",
                            f"Submission display_title phase mismatch: {display_title!r}")
        if fields.get("PR") != str(self.pr_number):
            raise GateError(EXIT_POLICY, "receipt_display_title_wrong_pr",
                            f"Submission display_title PR mismatch: {display_title!r}")
        if fields.get("HEAD") != target_head:
            raise GateError(EXIT_POLICY, "receipt_display_title_wrong_head",
                            f"Submission display_title HEAD mismatch: {display_title!r}")
        if fields.get("REPORT") != str(worker_report_comment_id):
            raise GateError(EXIT_POLICY, "receipt_display_title_wrong_report",
                            f"Submission display_title REPORT mismatch: {display_title!r}")
        raise GateError(EXIT_POLICY, "receipt_display_title_mismatch",
                        f"Submission display_title mismatch: {display_title!r}")

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
            run_id = os.environ.get("GITHUB_RUN_ID", "")
            attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
            if not re.fullmatch(r"[1-9][0-9]*", run_id):
                raise GateError(EXIT_INFRA, "hosted_submission_run_id_invalid",
                                "Submission success requires a positive GITHUB_RUN_ID")
            if attempt != "1":
                raise GateError(EXIT_INFRA, "hosted_submission_attempt_invalid",
                                "Submission success requires GITHUB_RUN_ATTEMPT == 1")
            submission_run_id = int(run_id)
            submission_run_attempt = int(attempt)
            result = {
                "state": "WAITING_FOR_CONTROLLER_REVIEW",
                "phase": "submission",
                "head_sha": self.expected_head,
                "worker_report_comment_id": self.worker_report_comment.get("id"),
                "submission_run_id": submission_run_id,
                "submission_run_attempt": submission_run_attempt,
                "worker_report_valid": True,
                "controller_review_present": False,
                "next_workstream_admitted": False,
            }
        elif self.phase == "review":
            if not self._review_receipt_validated:
                raise GateError(EXIT_POLICY, "submission_receipt_not_bound",
                                "Review cannot complete without a validated submission run receipt")
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


# === Workflow semantic audit (FIX3 §12) ===

def _wf_get_triggers(doc):
    """`on:` is parsed as YAML boolean True by PyYAML; accept both spellings."""
    if isinstance(doc, dict):
        for key in (True, "on", "On", "ON"):
            if key in doc:
                return doc[key]
    return {}


def _audit_workflow_job_steps(job, expected_head_input, phase):
    steps = job.get("steps")
    if not isinstance(steps, list):
        raise GateError(EXIT_POLICY, "workflow_job_steps_missing",
                        f"{phase} job has no steps block")
    checkout_ref = None
    persist_credentials = None
    command = None
    for step in steps:
        if not isinstance(step, dict):
            continue
        uses = step.get("uses", "")
        if isinstance(uses, str) and "actions/checkout" in uses:
            with_dict = step.get("with", {})
            if isinstance(with_dict, dict):
                checkout_ref = with_dict.get("ref")
                persist_credentials = with_dict.get("persist-credentials")
        if isinstance(step.get("run"), str):
            command = step.get("run", "")
    if persist_credentials is not False:
        raise GateError(EXIT_POLICY, "workflow_persist_credentials_true",
                        f"{phase} checkout does not set persist-credentials: false")
    if expected_head_input:
        if checkout_ref != "${{ inputs.expected_head }}":
            raise GateError(EXIT_POLICY, "workflow_checkout_expected_head_missing",
                            f"{phase} checkout does not bind inputs.expected_head")
    if command is None:
        raise GateError(EXIT_POLICY, "workflow_job_command_missing",
                        f"{phase} job has no run command")
    if phase == "advance":
        if "--worker-report-comment-id" in command:
            raise GateError(EXIT_POLICY, "workflow_advance_cli_arg_added",
                            "Advance Gate must not pass --worker-report-comment-id")
        return
    arg_missing = ("workflow_submission_cli_arg_missing" if phase == "submission"
                   else "workflow_review_cli_arg_missing")
    arg_hardcoded = ("workflow_submission_cli_arg_hardcoded" if phase == "submission"
                     else "workflow_review_cli_arg_hardcoded")
    if "--worker-report-comment-id" not in command:
        raise GateError(EXIT_POLICY, arg_missing,
                        f"{phase} command does not pass --worker-report-comment-id")
    if "inputs.worker_report_comment_id" not in command:
        raise GateError(EXIT_POLICY, arg_hardcoded,
                        f"{phase} command does not reference the exact input")


def _audit_workflow_yaml(workflow_path, expected_name, expected_path, expected_branch):
    """Structural audit of the gate workflow file (§12). Raises GateError on any
    breach. Missing/unparseable protected blocks exit 2; semantic mismatch exits 1."""
    if not os.path.exists(workflow_path):
        raise GateError(EXIT_INFRA, "workflow_yaml_missing",
                        f"Workflow file not found: {workflow_path}")
    if not HAS_YAML:
        raise GateError(EXIT_INFRA, "workflow_yaml_unparseable",
                        "PyYAML is not available to parse the workflow file")
    with open(workflow_path) as fh:
        try:
            doc = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            raise GateError(EXIT_INFRA, "workflow_yaml_unparseable",
                            f"Workflow YAML is not parseable: {exc}")
    if not isinstance(doc, dict):
        raise GateError(EXIT_INFRA, "workflow_yaml_unparseable",
                        "Workflow YAML root is not a mapping")

    if doc.get("name", "") != expected_name:
        raise GateError(EXIT_POLICY, "workflow_wrong_name",
                        f"Workflow name not {expected_name}")

    run_name = doc.get("run-name")
    if not isinstance(run_name, str):
        raise GateError(EXIT_POLICY, "workflow_run_name_missing",
                        "workflow-level run-name is missing")
    for token, label in (("inputs.phase", "workflow_run_name_missing_phase"),
                         ("inputs.pr_number", "workflow_run_name_missing_pr"),
                         ("inputs.expected_head", "workflow_run_name_missing_head"),
                         ("inputs.worker_report_comment_id", "workflow_run_name_missing_report")):
        if token not in run_name:
            raise GateError(EXIT_POLICY, label,
                            f"run-name does not bind {token}")

    triggers = _wf_get_triggers(doc)
    wd = triggers.get("workflow_dispatch", {}) if isinstance(triggers, dict) else {}
    wd_inputs = wd.get("inputs", {}) if isinstance(wd, dict) else {}
    if not isinstance(wd_inputs, dict):
        raise GateError(EXIT_INFRA, "workflow_inputs_block_missing",
                        "workflow_dispatch inputs block is missing")
    if "worker_report_comment_id" not in wd_inputs:
        raise GateError(EXIT_POLICY, "workflow_worker_report_input_missing",
                        "worker_report_comment_id input is missing")
    wrc = wd_inputs["worker_report_comment_id"]
    if isinstance(wrc, dict):
        if wrc.get("required") is not True:
            raise GateError(EXIT_POLICY, "workflow_worker_report_input_optional",
                            "worker_report_comment_id input is not required")
        if "default" in wrc:
            raise GateError(EXIT_POLICY, "workflow_worker_report_input_optional",
                            "worker_report_comment_id input has a default value")
    phase_cfg = wd_inputs.get("phase", {})
    phase_opts = phase_cfg.get("options", []) if isinstance(phase_cfg, dict) else []
    if "advance" in phase_opts:
        raise GateError(EXIT_POLICY, "workflow_advance_input_restored",
                        "manual advance phase input restored")

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        raise GateError(EXIT_INFRA, "workflow_jobs_block_missing",
                        "workflow jobs block is missing")

    submission_ids = []
    review_ids = []
    advance_ids = []
    manual_ids = []
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            raise GateError(EXIT_POLICY, "workflow_job_malformed",
                            f"job {job_id} is not a mapping")
        jname = job.get("name", "")
        if job_id == "manual" or jname in ("Manual Gate", "manual"):
            manual_ids.append(job_id)
        if jname == "Submission Gate":
            submission_ids.append(job_id)
        if jname == "Review Gate":
            review_ids.append(job_id)
        if jname == "Advance Gate":
            advance_ids.append(job_id)

    if manual_ids:
        raise GateError(EXIT_POLICY, "workflow_generic_manual_job_restored",
                        "generic Manual Gate job restored")

    if len(submission_ids) == 0:
        raise GateError(EXIT_POLICY, "workflow_submission_job_wrong_name",
                        "submission job not named Submission Gate")
    if len(submission_ids) > 1:
        raise GateError(EXIT_POLICY, "workflow_submission_job_duplicate",
                        "multiple Submission Gate jobs")
    sub_job = jobs[submission_ids[0]]
    sub_cond = sub_job.get("if", "")
    if not ("workflow_dispatch" in sub_cond and "inputs.phase" in sub_cond
            and ("'submission'" in sub_cond or '"submission"' in sub_cond)):
        raise GateError(EXIT_POLICY, "workflow_submission_condition_too_broad",
                        "Submission Gate condition is too broad")

    if len(review_ids) == 0:
        raise GateError(EXIT_POLICY, "workflow_review_job_exact",
                        "review job not named Review Gate")
    if len(review_ids) > 1:
        raise GateError(EXIT_POLICY, "workflow_review_job_duplicate",
                        "multiple Review Gate jobs")

    if len(advance_ids) == 0 or len(advance_ids) > 1:
        raise GateError(EXIT_POLICY, "workflow_advance_job_missing",
                        "Advance Gate job must exist exactly once")
    if "pull_request" not in jobs[advance_ids[0]].get("if", ""):
        raise GateError(EXIT_POLICY, "workflow_advance_condition_not_pr",
                        "Advance Gate condition is not pull_request-only")

    if isinstance(triggers, dict) and "pull_request_target" in triggers:
        raise GateError(EXIT_POLICY, "workflow_pull_request_target_used",
                        "pull_request_target is used")

    perms = doc.get("permissions", {})
    if isinstance(perms, dict):
        for perm_key, perm_val in perms.items():
            if perm_val not in ("read", None, "write"):
                raise GateError(EXIT_POLICY, "workflow_permissions_invalid",
                                f"permission {perm_key}: {perm_val}")
    if isinstance(perms, str) and perms.strip().lower() == "write-all":
        raise GateError(EXIT_POLICY, "workflow_permissions_not_read_only",
                        "permissions are write-all")

    _audit_workflow_job_steps(jobs[submission_ids[0]], expected_head_input=True, phase="submission")
    _audit_workflow_job_steps(jobs[review_ids[0]], expected_head_input=True, phase="review")
    _audit_workflow_job_steps(jobs[advance_ids[0]], expected_head_input=False, phase="advance")


def _run_workflow_audit(workflow_path):
    try:
        _audit_workflow_yaml(workflow_path, WORKFLOW_NAME_DEFAULT,
                             WORKFLOW_PATH_DEFAULT, None)
        print(json.dumps({"state": "WORKFLOW_AUDIT_OK",
                          "workflow": workflow_path}))
        return EXIT_OK
    except GateError as exc:
        print(json.dumps({"state": "REJECTED",
                          "workflow": workflow_path,
                          "guard_label": exc.label,
                          "message": exc.message}))
        return exc.exit_code


def main():
    parser = argparse.ArgumentParser(description="Workstream Review Gate")
    parser.add_argument("--phase", required=False,
                        choices=["advance", "submission", "review"])
    parser.add_argument("--pr-number", type=int, default=2)
    parser.add_argument("--expected-head", required=False)
    parser.add_argument("--repo", default="oxcandy-lgtm/macsteam")
    parser.add_argument("--fixtures", default=None,
                        help="Fixture directory for offline testing")
    parser.add_argument("--policy", default=POLICY_PATH_DEFAULT)
    parser.add_argument("--max-items", type=int, default=1000)
    parser.add_argument("--worker-report-comment-id", type=int, default=None,
                        help="Comment ID of the worker report (submission phase)")
    parser.add_argument("--submission-run-id", type=int, default=None,
                        help="Expected submission run ID (review phase)")
    parser.add_argument("--check-workflow", default=None,
                        help="Run the workflow semantic audit on the given YAML path")

    args = parser.parse_args()

    if args.check_workflow:
        sys.exit(_run_workflow_audit(args.check_workflow))

    gate = Gate(
        phase=args.phase,
        pr_number=args.pr_number,
        expected_head=args.expected_head,
        repo=args.repo,
        fixtures_dir=args.fixtures,
        policy_path=args.policy,
        max_items=args.max_items,
        worker_report_comment_id=args.worker_report_comment_id,
        submission_run_id=args.submission_run_id,
    )

    sys.exit(gate.run())


if __name__ == "__main__":
    main()
