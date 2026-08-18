#!/usr/bin/env python3
"""Ratchet gate for zizmor findings.

zizmor reports 150+ pre-existing `template-injection` findings against
`inputs.*` in this repo's reusable workflows. Suppressing the whole audit
would hide genuinely new problems, and a blanket auto-fix would rewrite
expansions inside quoted heredocs where shell expansion never happens.

Instead, this script pins the accepted count per (file, audit) pair in
`.github/zizmor-baseline.json` and fails when a file's count exceeds its
baseline. New findings block the PR; fixing findings is always allowed and
the script tells you to lower the baseline so the fix cannot regress.

Usage:
    zizmor --format json . > findings.json
    python3 scripts/zizmor-ratchet.py findings.json            # check
    python3 scripts/zizmor-ratchet.py findings.json --update   # rewrite baseline
"""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import sys

BASELINE_PATH = pathlib.Path(".github/zizmor-baseline.json")


def load_findings(path: pathlib.Path) -> collections.Counter[tuple[str, str]]:
    """Count zizmor findings keyed by (workflow path, audit id)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    counts: collections.Counter[tuple[str, str]] = collections.Counter()
    for finding in data:
        locations = finding.get("locations") or []
        if not locations:
            continue
        key = locations[0].get("symbolic", {}).get("key", {}).get("Local", {})
        given = key.get("given_path", "")
        counts[(given.removeprefix("./"), finding["ident"])] += 1
    return counts


def to_baseline(counts: collections.Counter[tuple[str, str]]) -> dict:
    grouped: dict[str, dict[str, int]] = {}
    for (path, ident), count in sorted(counts.items()):
        grouped.setdefault(path, {})[ident] = count
    return grouped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("findings", type=pathlib.Path, help="zizmor --format json output")
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the baseline from the current findings instead of checking",
    )
    args = parser.parse_args()

    counts = load_findings(args.findings)

    if args.update:
        BASELINE_PATH.write_text(
            json.dumps(to_baseline(counts), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Wrote baseline for {len(counts)} (file, audit) pairs to {BASELINE_PATH}")
        return 0

    baseline_raw = json.loads(BASELINE_PATH.read_text(encoding="utf-8")) if BASELINE_PATH.exists() else {}
    baseline = {
        (path, ident): count
        for path, audits in baseline_raw.items()
        for ident, count in audits.items()
    }

    regressions = []
    improvements = []
    for key in sorted(set(baseline) | set(counts)):
        path, ident = key
        allowed = baseline.get(key, 0)
        actual = counts.get(key, 0)
        if actual > allowed:
            regressions.append((path, ident, allowed, actual))
        elif actual < allowed:
            improvements.append((path, ident, allowed, actual))

    for path, ident, allowed, actual in improvements:
        print(f"::notice file={path}::{ident}: {allowed} → {actual} findings. Run scripts/zizmor-ratchet.py --update to lock the fix in.")

    if not regressions:
        total = sum(counts.values())
        print(f"OK: {total} zizmor findings, none above baseline.")
        return 0

    for path, ident, allowed, actual in regressions:
        print(
            f"::error file={path}::zizmor {ident}: {actual} findings, baseline allows {allowed}. "
            "Fix the new finding, or justify it and update .github/zizmor-baseline.json in the same PR."
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
