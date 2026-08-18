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

2. reusable-concurrency
   A reusable workflow cannot key a concurrency group per calling job —
   `github.run_id`, `github.workflow` and `github.ref` are identical for every
   job of a caller's run, so sibling and matrix jobs share one group and cancel
   each other. This silently killed real CI jobs. Concurrency belongs to the
   caller. Allowed: `cancel-in-progress: false` (queues instead of cancelling)
   and groups keyed on `inputs.*`, which the caller varies per call.

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


def cancelling_concurrency(text: str) -> str | None:
    """Return the offending group when a reusable workflow can cancel its siblings."""
    match = re.search(r"^concurrency:\n((?:^[ \t]+.*\n)+)", text, re.MULTILINE)
    if match is None:
        return None
    block = match.group(1)
    if not re.search(r"cancel-in-progress:\s*true", block):
        return None
    group = re.search(r"group:\s*(.+)", block)
    key = group.group(1).strip() if group else block.strip()
    if "inputs." in key:
        return None
    return key


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

        offending = cancelling_concurrency(text)
        if offending is not None:
            print(
                f"::error file={path}::Reusable workflow declares a cancelling "
                f"`concurrency:` group ({offending}) — github.run_id/workflow/ref are "
                "identical across sibling and matrix jobs, so those jobs cancel each "
                "other. Remove it and let the caller declare concurrency."
            )
            failures += 1

    if failures:
        print(f"\n{failures} hygiene failure(s) across {checked} reusable workflow(s).")
        return 1

    print(f"OK: {checked} reusable workflow(s) pass hygiene checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
