#!/usr/bin/env python3
"""
Source code mutation applier for workstage-review-gate — U1R18-R7-FIX3.

Usage:
  python3 apply-source-mutation.py <MUTATION_NAME> <gate_script_path>

Each mutation applies a small, targeted string replacement to the Python
source code of scripts/workstage-review-gate.py. These represent realistic
bug introductions that should cause GREEN fixtures to fail (exit non-zero),
proving the test suite catches regressions.

Mutation categories:
  review/    — review phase controller review validation
  advance/   — advance phase parent review routing
  report/    — worker report field validation
  ci/        — CI run and job validation
  pr/        — PR state and policy binding
  routing/   — parent review routing (bootstrap/repair/normal)
  submission/ — FIX2 submission phase validation
  receipt/    — FIX2 submission run receipt validation
"""

import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def apply_mutation(source, mutation_name):
    """Apply a mutation to the gate script source code.

    Returns (mutated_source, description) or raises ValueError for unknown mutations.
    """
    mutations = {
        # === M1: review/ — Use first review instead of latest ===
        "m1_first_review_not_latest": (
            'latest = controller_reviews[-1]',
            'latest = controller_reviews[0]',
            "Review phase: select first review instead of latest (breaks latest-decision authority)"
        ),

        # === M2: review/ — Invert before_report timestamp comparison ===
        "m2_invert_before_report": (
            'if review_time < worker_time:',
            'if review_time > worker_time:',
            "Review phase: invert before_report timestamp comparison (false rejection of valid reviews)"
        ),

        # === M3: review/ — Change GREEN_ to RED_ in classification check ===
        "m3_green_to_red_classification": (
            'not data.get("classification", "").startswith("GREEN_")',
            'not data.get("classification", "").startswith("RED_")',
            "Review phase: check for RED_ classification instead of GREEN_ (rejects valid GREEN reviews)"
        ),

        # === M4: report/ — Change workstream check ===
        "m4_wrong_workstream": (
            'if workstream != expected_ws:',
            'if workstream != "U1R18-R7":',
            "Worker report: check for U1R18-R7 instead of the active FIX3 workstream (rejects valid workstream)"
        ),

        # === M5: report/ — Invert before_commit timestamp comparison ===
        "m5_invert_before_commit": (
            'if comment_date < commit_date:',
            'if comment_date > commit_date:',
            "Worker report: invert before_commit timestamp comparison (false rejection of valid reports)"
        ),

        # === M6: advance/ — Change bootstrap state check ===
        "m6_bootstrap_state_commented": (
            'if found.get("state") != "APPROVED":',
            'if found.get("state") != "COMMENTED":',
            "Bootstrap: require COMMENTED instead of APPROVED (rejects valid bootstrap review)"
        ),

        # === M7: advance/ — APPROVED-only (remove COMMENTED acceptance) ===
        "m7_approved_only_no_commented": (
            'if state not in ("COMMENTED", "APPROVED"):',
            'if state != "APPROVED":',
            "Normal parent review: only accept APPROVED state (rejects COMMENTED reviews)"
        ),

        # === M8: review/ — Invert head_sha JSON check ===
        "m8_invert_head_sha_check": (
            'if json_data.get("head_sha") != self.parent_sha:',
            'if json_data.get("head_sha") == self.parent_sha:',
            "Normal parent: invert head_sha mismatch check (rejects valid reviews)"
        ),

        # === M9: report/ — Invert commit_count check ===
        "m9_invert_commit_count": (
            'if report.get("commit_count") != 1:',
            'if report.get("commit_count") == 1:',
            "Worker report: invert commit_count check (rejects valid count of 1)"
        ),

        # === M10: advance/ — Invert decision accepted check ===
        "m10_invert_decision_check": (
            'if decision != "accepted":',
            'if decision == "accepted":',
            "Parent review: skip accepted reviews instead of non-accepted (no valid reviews found)"
        ),

        # === M11: ci/ — Invert required_jobs subset check ===
        "m11_invert_required_jobs": (
            'if not required_jobs.issubset(report_jobs):',
            'if required_jobs.issubset(report_jobs):',
            "Worker report: invert CI jobs subset check (rejects valid job sets)"
        ),

        # === M12: pr/ — Invert draft PR check ===
        "m12_invert_draft_check": (
            'if not self.pr.get("draft", False):',
            'if self.pr.get("draft", False):',
            "PR state: invert draft check (rejects valid draft PRs)"
        ),

        # === M13: pr/ — Change mergeable requirement ===
        "m13_wrong_mergeable": (
            'if mergeable is True or mergeable == "MERGEABLE" or str(mergeable).upper() == "MERGEABLE":',
            'if mergeable is False or mergeable == "CONFLICTING":',
            "PR state: require CONFLICTING instead of MERGEABLE (rejects valid mergeable PRs)"
        ),

        # === M14: routing/ — Remove bootstrap routing ===
        "m14_remove_bootstrap_routing": (
            'if self.parent_sha == bootstrap_head and self.expected_head == bootstrap_child:',
            'if False:  # bootstrap routing disabled by mutation',
            "Routing: disable bootstrap path (bootstrap review treated as normal, fails)"
        ),

        # === M15: report/ — Invert stop field check ===
        "m15_invert_stop_check": (
            'if not report.get("stop"):',
            'if report.get("stop"):',
            "Worker report: invert stop check (rejects valid stop=True)"
        ),

        # === M16: report/ — Allow non-null gate_submission_run_id ===
        "m16_allow_non_null_submission_run_id": (
            'if report.get("gate_submission_run_id") is not None:',
            'if report.get("gate_submission_run_id") is None:',
            "Worker report: invert null gate_submission_run_id check (allows non-null)"
        ),

        # === M17: submission/ — Invert worker_report_comment_id existence ===
        "m17_invert_comment_id_required": (
            'if self.worker_report_comment_id is None:',
            'if self.worker_report_comment_id is not None:',
            "Submission: invert worker_report_comment_id requirement (allows missing comment id)"
        ),

        # === M18: receipt/ — Invert submission run status check ===
        "m18_invert_submission_status_check": (
            'if run.get("status") != "completed":',
            'if run.get("status") == "completed":',
            "Submission receipt: invert status != completed check (rejects valid completed runs)"
        ),

        # === M19: receipt/ — Invert submission run conclusion check ===
        "m19_invert_submission_conclusion_check": (
            'if run.get("conclusion") != "success":',
            'if run.get("conclusion") == "success":',
            "Submission receipt: invert conclusion != success check (rejects valid successful runs)"
        ),

        # === M20: receipt/ — Invert submission gate job check ===
        "m20_invert_gate_job_status": (
            'if gate_job.get("status") != "completed":',
            'if gate_job.get("status") == "completed":',
            "Submission job: invert job status completed check (rejects valid completed jobs)"
        ),

        # === M21: receipt/ — Invert submission gate job conclusion ===
        "m21_invert_gate_job_conclusion": (
            'if conclusion != "success":',
            'if conclusion == "success":',
            "Submission job: invert job conclusion success check (rejects valid successful jobs)"
        ),

        # === M26: receipt/ — Read dynamic identity from run.name not display_title ===
        "receipt_dynamic_identity_reads_name_not_display_title": (
            'display_title = run.get("display_title", "")',
            'display_title = run.get("name", "")',
            "Submission receipt: read dynamic identity from run.name instead of display_title (rejects valid runs)"
        ),

        # === M22: receipt/ — Skip submission run chronology check ===
        "m22_skip_chronology_check": (
            'if report_time > run_start_time:',
            'if report_time < run_start_time:',
            "Submission receipt: invert chronology check (allows invalid ordering)"
        ),

        # === M23: receipt/ — Skip submission completed-after-review check ===
        "m23_invert_completed_after_review": (
            'if completed_at > review_submit_time:',
            'if completed_at < review_submit_time:',
            "Submission receipt: invert completed-after-review check (allows invalid ordering)"
        ),

        # === M24: receipt/ — Skip submission run attempt check ===
        "m24_skip_run_attempt_check": (
            'if run_attempt is not None and run_attempt != 1:\n            raise GateError(EXIT_POLICY, "submission_run_attempt_gt_one",',
            'if run_attempt is not None and run_attempt == 1:\n            raise GateError(EXIT_POLICY, "submission_run_attempt_gt_one",',
            "Submission: invert run_attempt check (rejects attempt != 1)"
        ),

        # === M25: receipt/ — Bypass _validate_submission_run_receipt ===
        "m25_bypass_submission_receipt": (
            'self._validate_submission_receipt()',
            '# self._validate_submission_receipt()  # bypassed by mutation',
            "Review: bypass submission run receipt validation entirely"
        ),

        # === BRDG-1: anti-self-authorization — policy read as scope authority ===
        # If a bridge's path scope were taken from the policy instead of the
        # (unedited) comment, a self-expanding policy would widen the envelope.
        "bridge_policy_read_as_scope_authority": (
            'self._bridge_source_scope = ("exact", source_exact, "prefix", source_prefixes)',
            'self._bridge_source_scope = ("exact", [self.policy.get("bridge_workstream") or "unknown"], "prefix", ["scripts/"])',
            "Bridge anti-self-auth: read source scope from policy instead of comment (rejects an explicit unknown path)"
        ),

# === BRDG-2: anti-self-authorization — restrict source scope instead of comment ===
        # Source fix changed files must always be bounded by the (unedited)
        # comment scope; a code change that silently narrows the scope is still
        # caught because the changed source files cannot fit the narrow scope.
        "bridge_drop_source_scope_check": (
            '        for filepath in source_files:\n            if not self._bridge_path_in_scope(filepath, self._bridge_source_scope):\n                raise GateError(EXIT_POLICY, "red_source_fix_forbidden_path",',
            '        for filepath in source_files:\n            if not self._bridge_path_in_scope(filepath, ("exact", ["unknown/path/only.swift"], "prefix", ["unknown/"])):\n            raise GateError(EXIT_POLICY, "red_source_fix_forbidden_path",',
            "Bridge self-auth: restrict source scope instead of honoring comment (rejects valid source files)"
        ),

        # === GATE1-FIX1: rejected review object binding anti-bypass ===
        "bypass_rejected_review_fetch": (
            'review = self.client.get_review_by_id(expected_id)',
            'review = {}  # bypassed by mutation',
            "Rejected review: replace exact object fetch with an empty object (no valid review found)"
        ),

        "bypass_rejected_review_classification_check": (
            'if json_data.get("classification") != expected_classification:',
            'if json_data.get("classification") == expected_classification:',
            "Rejected review: invert classification check (rejects valid classification)"
        ),

        # === GATE1-FIX1: failed advance binding anti-bypass ===
        "bypass_failed_advance_conclusion": (
            'if run_conclusion != "failure":',
            'if run_conclusion == "failure":',
            "Failed advance: invert conclusion check (rejects valid failed run)"
        ),

        "bypass_failed_advance_job_check": (
            'if isinstance(job, dict) and job.get("name") == "Advance Gate":',
            'if isinstance(job, dict) and job.get("name") == "Wrong Gate":',
            "Failed advance: look for a nonexistent job name (rejects valid gate job)"
        ),

        "bypass_failed_advance_guard_check": (
            'if actual_guard != guard:',
            'if actual_guard == guard:',
            "Failed advance: invert guard comparison (rejects matching guard)"
        ),

        # === GATE1-FIX1: source authorization chronology anti-bypass ===
        "bypass_source_auth_chronology": (
            'if not self._check_comment_before_commit_ts(comment, bridge_date):',
            'if self._check_comment_before_commit_ts(comment, bridge_date):',
            "Source auth: invert chronology comparison (rejects valid chronology)"
        ),

        # === GATE1-FIX1: gate-fix authorization anti-bypass ===
        "gate_fix_scope_read_from_policy": (
            'self._gate_fix_scope = ("exact", exact, "prefix", prefixes)',
            'self._gate_fix_scope = ("exact", [], "prefix", ["unknown/"])',
            "Gate-fix: read child scope from a fixed narrow list (rejects valid gate files)"
        ),

        "gate_fix_chronology_bypassed": (
            'if not self._check_comment_before_commit_ts(\n                {"created_at": getattr(self, "gate_fix_auth_created_at", None)},\n                head_date_str):',
            'if self._check_comment_before_commit_ts(\n                {"created_at": getattr(self, "gate_fix_auth_created_at", None)},\n                head_date_str):',
            "Gate-fix: invert child chronology check (rejects valid authorization)"
        ),
    }

    if mutation_name not in mutations:
        raise ValueError(f"Unknown mutation: {mutation_name}")

    old, new, desc = mutations[mutation_name]
    if old not in source:
        raise ValueError(f"Mutation pattern not found in source: {old}")
    mutated = source.replace(old, new, 1)
    return mutated, desc


def main():
    if len(sys.argv) != 3:
        print("Usage: apply-source-mutation.py <MUTATION_NAME> <gate_script_path>", file=sys.stderr)
        sys.exit(2)

    mutation_name = sys.argv[1]
    gate_script_path = sys.argv[2]

    with open(gate_script_path, "r") as f:
        source = f.read()

    mutated_source, desc = apply_mutation(source, mutation_name)

    with open(gate_script_path, "w") as f:
        f.write(mutated_source)

    print(f"Applied {mutation_name}: {desc}")


if __name__ == "__main__":
    main()
