#!/usr/bin/env python3
"""Fail only when a changed Java or Kotlin file is both complex and a hotspot.

A one-line edit in a quiet file passes, even if that file is already complex.
Complexity is file-level decision count, so splitting a function inside the
same file does not drop the number. The hotspot set is the top 10% of Java
and Kotlin files by git commit touches, including ties at the cutoff. Files
that share only the minimum frequency are quiet whenever a strictly hotter
file exists.

Existing complex hotspots are printed and do not fail the build. This gate
does not raise the complexity ceiling and does not write a baseline.
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

DEFAULT_COMPLEX_CCN = 10
DEFAULT_TOP_FRACTION = 0.10
DECISION = __import__("re").compile(r"\b(?:if|when|while|for|catch)\b|&&|\|\||\?:")
SOURCE_SUFFIXES = (".java", ".kt", ".kts")


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), *args],
        text=True,
        stderr=subprocess.PIPE,
    )


def require_ref(repo: Path, base: str) -> None:
    try:
        git(repo, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"hotspot-gate: base ref {base} is missing\n")
        if exc.stderr:
            sys.stderr.write(exc.stderr)
        raise SystemExit(1) from exc


def strip_noise(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith('"""', i) or text.startswith("'''", i):
            quote = text[i : i + 3]
            end = text.find(quote, i + 3)
            i = n if end < 0 else end + 3
            continue
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def file_ccn(path: Path) -> int:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 1
    return 1 + len(DECISION.findall(strip_noise(text)))


def is_source(path: str) -> bool:
    if ".." in path.split("/"):
        return False
    return path.endswith(SOURCE_SUFFIXES)


def name_only(raw: str) -> set[str]:
    return {line.strip() for line in raw.splitlines() if line.strip()}


def changed_sources(repo: Path, base: str) -> list[str]:
    committed = git(
        repo,
        "diff",
        "--name-only",
        "--diff-filter=ACMR",
        f"{base}...HEAD",
        "--",
        "*.java",
        "*.kt",
        "*.kts",
    )
    worktree = git(
        repo,
        "diff",
        "--name-only",
        "--diff-filter=ACMR",
        "HEAD",
        "--",
        "*.java",
        "*.kt",
        "*.kts",
    )
    staged = git(
        repo,
        "diff",
        "--name-only",
        "--diff-filter=ACMR",
        "--cached",
        "--",
        "*.java",
        "*.kt",
        "*.kts",
    )
    untracked = git(
        repo,
        "ls-files",
        "--others",
        "--exclude-standard",
        "--",
        "*.java",
        "*.kt",
        "*.kts",
    )
    names = name_only(committed) | name_only(worktree) | name_only(staged) | name_only(untracked)
    return sorted(path for path in names if is_source(path))


def frequencies(repo: Path) -> dict[str, int]:
    raw = git(repo, "log", "--name-only", "--pretty=format:", "--", "*.java", "*.kt", "*.kts")
    counts: dict[str, int] = {}
    for line in raw.splitlines():
        path = line.strip()
        if is_source(path):
            counts[path] = counts.get(path, 0) + 1
    return counts


def hotspot_set(counts: dict[str, int], fraction: float) -> set[str]:
    if not counts or fraction <= 0 or fraction > 1:
        return set()
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    cutoff_index = max(1, math.ceil(len(ranked) * fraction)) - 1
    cutoff = ranked[cutoff_index][1]
    minimum = ranked[-1][1]
    chosen = {path for path, count in ranked if count >= cutoff and count > 0}
    if cutoff == minimum and any(count > minimum for _, count in ranked):
        chosen = {path for path, count in ranked if count > minimum}
    return chosen


def complex_hotspots(
    repo: Path,
    hot: set[str],
    counts: dict[str, int],
    ceiling: int,
) -> list[tuple[str, int, int]]:
    found: list[tuple[str, int, int]] = []
    for rel in sorted(hot):
        path = repo / rel
        if not path.is_file():
            continue
        ccn = file_ccn(path)
        if ccn >= ceiling:
            found.append((rel, ccn, counts.get(rel, 0)))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--top-fraction", type=float, default=DEFAULT_TOP_FRACTION)
    parser.add_argument("--complex-ccn", type=int, default=DEFAULT_COMPLEX_CCN)
    args = parser.parse_args()
    if args.top_fraction <= 0 or args.top_fraction > 1:
        sys.stderr.write("hotspot-gate: --top-fraction must be in (0, 1]\n")
        return 2
    if args.complex_ccn != DEFAULT_COMPLEX_CCN:
        sys.stderr.write(
            "hotspot-gate: refusing to change the complexity ceiling "
            f"from {DEFAULT_COMPLEX_CCN}\n"
        )
        return 2
    repo = Path(args.repo).resolve()
    require_ref(repo, args.base)
    changed = changed_sources(repo, args.base)
    counts = frequencies(repo)
    hot = hotspot_set(counts, args.top_fraction)
    changed_set = set(changed)
    findings = complex_hotspots(repo, hot, counts, args.complex_ccn)
    visible = [item for item in findings if item[0] not in changed_set]
    for rel, ccn, touches in visible:
        print(
            "hotspot-gate: existing hotspot (does not fail): "
            f"{rel} ccn={ccn} commits={touches}"
        )
    if visible:
        print(
            "hotspot-gate: "
            f"{len(visible)} existing hotspot(s) visible; they do not fail the build"
        )
    if not changed:
        if not visible:
            print("hotspot-gate: no existing hotspots")
        print(f"hotspot-gate: no Java or Kotlin changes versus {args.base}")
        return 0
    failures: list[str] = []
    for rel in changed:
        path = repo / rel
        if not path.is_file():
            continue
        ccn = file_ccn(path)
        touches = counts.get(rel, 0)
        is_hot = rel in hot
        is_complex = ccn >= args.complex_ccn
        if is_hot and is_complex:
            failures.append(f"{rel} (ccn={ccn}, commits={touches}) is a complex hotspot")
        else:
            print(f"hotspot-gate: pass {rel} ccn={ccn} commits={touches} hot={is_hot}")
    if failures:
        sys.stderr.write("hotspot-gate: FAIL\n")
        for line in failures:
            sys.stderr.write(f"  {line}\n")
        return 1
    if not visible:
        print("hotspot-gate: no existing hotspots")
    print("hotspot-gate: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
