#!/usr/bin/env python3
"""Fail unless PIT killed every mutant in this module's report.

Reads target/pit-reports/mutations.xml. There is no survived ceiling to raise.
A missing report, an empty run, a survivor, or an uncovered mutant fails.
This script does not run PIT and does not write a baseline.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / "target" / "pit-reports" / "mutations.xml"
DETECTED = {"KILLED", "TIMED_OUT", "MEMORY_ERROR"}


def evaluate(root: ET.Element) -> str | None:
    """Return an error string when the export does not kill every mutant."""
    if root.tag != "mutations":
        return "not a pit mutations export"
    mutations = list(root.findall("mutation"))
    if not mutations:
        return "empty pit export"
    for mutation in mutations:
        detected = mutation.get("detected")
        status = mutation.get("status")
        if detected != "true" or status not in DETECTED:
            label = status or "missing status"
            return f"{label} is not killed"
    return None


def main() -> int:
    if "--ceiling" in sys.argv or "--threshold" in sys.argv or "--write-baseline" in sys.argv:
        print("pit-mutation: refusing to raise the mutation ceiling", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    if not args.report.is_file():
        print(f"pit-mutation: FAIL missing report {args.report}", file=sys.stderr)
        return 2
    try:
        tree = ET.parse(args.report)
        problem = evaluate(tree.getroot())
    except ET.ParseError as exc:
        print(f"pit-mutation: FAIL {exc}", file=sys.stderr)
        return 1
    if problem:
        print(f"pit-mutation: FAIL {problem}", file=sys.stderr)
        return 1
    killed = len(list(tree.getroot().findall("mutation")))
    print(f"pit-mutation: PASS killed {killed} of {killed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
