#!/usr/bin/env python3
"""
Source code mutation applier for workstage-review-gate — U1R18-R7-FIX1.

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
            'if workstream != "U1R18-R7-FIX1":',
            'if workstream != "U1R18-R7":',
            "Worker report: check for U1R18-R7 instead of U1R18-R7-FIX1 (rejects valid workstream)"
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
