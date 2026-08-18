#!/usr/bin/env python3
"""Hygiene checks for this repo's reusable workflows.

Every other NeuralTrust repo consumes these workflows, so a mistake here breaks
pipelines org-wide. These are rules that actionlint and zizmor cannot express.

Checks
------
1. local-action-path
   A reusable workflow runs in the *caller's* checkout, so `uses: ./...`
   resolves against the consumer repo, not this one. Composite actions must be
   referenced by full repo ref. This is the exact bug that broke consumer
   deploys.

2. missing-concurrency
   Reusable (`workflow_call`) workflows must declare a workflow-level
   `concurrency:` block. Without one, a caller that invokes the same reusable
   workflow twice in a run has no way to scope queueing, and superseded runs
   keep burning runner minutes. Self-triggered workflows in this repo (e.g.
   `workflows-ci.yml`) set their own concurrency and are not covered by this
   rule, since they are not consumed by other repos.

Exit code is 1 when any check fails, so this can gate CI directly.
"""

from __future__ import annotations

import pathlib
import re
import sys

WORKFLOWS = pathlib.Path(".github/workflows")
LOCAL_ACTION = re.compile(r"uses:\s*\./\.github/actions/")


def is_reusable(text: str) -> bool:
    """True when the workflow exposes a `workflow_call` trigger."""
    return re.search(r"^\s{2}workflow_call:", text, re.MULTILINE) is not None


def has_top_level_concurrency(text: str) -> bool:
    """True when the workflow declares a workflow-level `concurrency:` block."""
    return re.search(r"^concurrency:", text, re.MULTILINE) is not None


def main() -> int:
    failures = 0
    checked = 0

    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if not is_reusable(text):
            continue
        checked += 1

        for lineno, line in enumerate(text.splitlines(), start=1):
            if LOCAL_ACTION.search(line):
                print(
                    f"::error file={path},line={lineno}::Reusable workflow references a local "
                    "action path (./.github/actions/...). Use "
                    "NeuralTrust/workflows/.github/actions/<name>@main — local paths resolve "
                    "against the caller repo and break consumers."
                )
                failures += 1

        if not has_top_level_concurrency(text):
            print(
                f"::error file={path}::Reusable workflow is missing a workflow-level "
                "`concurrency:` block. Add one keyed on `inputs.concurrency_key` so callers "
                "can scope queueing, e.g.\n"
                "  concurrency:\n"
                "    group: <prefix>-${{ github.workflow }}-${{ github.ref }}-"
                "${{ inputs.concurrency_key || github.run_id }}\n"
                "    cancel-in-progress: false"
            )
            failures += 1

    if failures:
        print(f"\n{failures} hygiene failure(s) across {checked} reusable workflow(s).")
        return 1

    print(f"OK: {checked} reusable workflow(s) pass hygiene checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
