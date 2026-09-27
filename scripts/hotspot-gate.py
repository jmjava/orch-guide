#!/usr/bin/env python3
"""Fail only when a changed Kotlin or Java file is both complex and hot.

Complex means a cyclomatic-style decision count of at least 15
(1 + if/for/while/catch/when/case/&&/||), the same bar as detekt ComplexMethod.
Hot means the file is in the top 10% of current src Kotlin and Java files by
commit count on HEAD. Ties at the cutoff stay in the set. A file that is only
complex, or only frequently changed, does not fail this gate.
"""

from __future__ import annotations

import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPLEX_AT = 15
TOP_FRACTION = 0.10
DECISION = re.compile(r"\b(?:if|for|while|catch|when|case)\b|&&|\|\|")


def git_lines(args: list[str]) -> list[str]:
    result = subprocess.run(
        args,
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode or 1)
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def is_source(path: str) -> bool:
    if not path.startswith("src/"):
        return False
    if not path.endswith((".kt", ".java")):
        return False
    if "/build/" in path:
        return False
    return os.path.isfile(os.path.join(ROOT, path))


def mask_source(src: str) -> str:
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            if end < 0:
                out.append(" " * (n - i))
                break
            out.append(" " * (end + 2 - i))
            i = end + 2
            continue
        if src.startswith("//", i):
            end = src.find("\n", i)
            if end < 0:
                end = n
            out.append(" " * (end - i))
            i = end
            continue
        if src[i] in "\"'":
            quote = src[i]
            triple = quote * 3
            if src.startswith(triple, i):
                end = src.find(triple, i + 3)
                if end < 0:
                    out.append(" " * (n - i))
                    break
                out.append(" " * (end + 3 - i))
                i = end + 3
                continue
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == quote:
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            out.append(" " * (j - i))
            i = j
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def complexity(path: str) -> int:
    with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as handle:
        masked = mask_source(handle.read())
    return 1 + len(DECISION.findall(masked))


def require_origin_main() -> None:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", "origin/main"],
        cwd=ROOT,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.stderr.write("origin/main is required\n")
        raise SystemExit(1)


def changed_sources() -> list[str]:
    names: set[str] = set()
    for args in (
        ["git", "diff", "--name-only", "--diff-filter=ACMR", "origin/main...HEAD"],
        ["git", "diff", "--name-only", "--diff-filter=ACMR"],
        ["git", "diff", "--name-only", "--diff-filter=ACMR", "--cached"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ):
        names.update(git_lines(args))
    return sorted(path for path in names if is_source(path))


def commit_counts(tracked: list[str]) -> dict[str, int]:
    wanted = set(tracked)
    counts = {path: 0 for path in tracked}
    log = subprocess.run(
        ["git", "log", "--pretty=format:", "--name-only", "HEAD", "--", "src"],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if log.returncode != 0:
        sys.stderr.write(log.stderr)
        raise SystemExit(log.returncode or 1)
    for line in log.stdout.splitlines():
        path = line.strip()
        if path in wanted:
            counts[path] += 1
    return counts


def top_set(tracked: list[str], counts: dict[str, int]) -> tuple[set[str], int]:
    positive = sorted(
        (path for path in tracked if counts.get(path, 0) > 0),
        key=lambda path: (-counts[path], path),
    )
    if not positive:
        return set(), 0
    cutoff_index = max(1, math.ceil(len(positive) * TOP_FRACTION)) - 1
    cutoff = counts[positive[cutoff_index]]
    return {path for path in positive if counts[path] >= cutoff}, cutoff


def gate() -> list[str]:
    require_origin_main()
    tracked = [path for path in git_lines(["git", "ls-files", "src"]) if is_source(path)]
    counts = commit_counts(tracked)
    hot, cutoff = top_set(tracked, counts)
    changed = changed_sources()
    if not changed:
        print("hotspot gate: no changed Kotlin or Java files versus origin/main")
        return []
    failures: list[str] = []
    for path in changed:
        if path not in hot:
            continue
        score = complexity(path)
        if score >= COMPLEX_AT:
            failures.append(
                f"{path} is complex (complexity {score}) and in the top "
                f"change-frequency set ({counts.get(path, 0)} commits, cutoff {cutoff})"
            )
    if failures:
        return failures
    print(
        "hotspot gate: checked "
        f"{len(changed)} changed Kotlin/Java file(s); "
        f"top change-frequency set is {len(hot)} file(s) at or above {cutoff} commits; "
        "none of the changed files are both complex and in that set"
    )
    return []


def git(root: str, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )


def write(root: str, path: str, text: str) -> None:
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as handle:
        handle.write(text)


def self_test() -> None:
    global ROOT
    original = ROOT
    tmp = tempfile.mkdtemp(prefix="hotspot-gate-")
    simple = "fun a() = 1\n"
    complex_body = "fun c(x: Int): Int {\n" + "".join(
        f"    if (x == {i}) return {i}\n" for i in range(15)
    ) + "    return -1\n}\n"
    try:
        ROOT = tmp
        git(tmp, "init", "-q")
        git(tmp, "config", "user.email", "ratchet@example.com")
        git(tmp, "config", "user.name", "ratchet")
        for index in range(9):
            write(tmp, f"src/f{index}.kt", simple)
        write(tmp, "src/hot.kt", simple)
        git(tmp, "add", "src")
        git(tmp, "commit", "-q", "-m", "init")
        for index in range(12):
            with open(os.path.join(tmp, "src/hot.kt"), "a", encoding="utf-8") as handle:
                handle.write(f"// tick {index}\n")
            git(tmp, "add", "src/hot.kt")
            git(tmp, "commit", "-q", "-m", f"hot {index}")
        git(tmp, "update-ref", "refs/remotes/origin/main", "HEAD")

        if gate():
            raise SystemExit("hotspot self-test: clean tree must pass")

        write(tmp, "src/f0.kt", complex_body)
        git(tmp, "add", "src/f0.kt")
        git(tmp, "commit", "-q", "-m", "complex cold")
        if gate():
            raise SystemExit("hotspot self-test: complex but cold file must pass")

        git(tmp, "reset", "--hard", "-q", "origin/main")
        write(tmp, "src/hot.kt", simple + "// touch\n")
        git(tmp, "add", "src/hot.kt")
        git(tmp, "commit", "-q", "-m", "hot simple")
        if gate():
            raise SystemExit("hotspot self-test: hot but simple file must pass")

        git(tmp, "reset", "--hard", "-q", "origin/main")
        write(tmp, "src/hot.kt", complex_body)
        git(tmp, "add", "src/hot.kt")
        git(tmp, "commit", "-q", "-m", "hot complex")
        failures = gate()
        if not failures:
            raise SystemExit("hotspot self-test: complex and hot file must fail")
        if not any("src/hot.kt" in line and "complex" in line for line in failures):
            raise SystemExit("hotspot self-test: failure must name src/hot.kt")
        print("hotspot self-test: complex-only, hot-only, and complex-and-hot OK")
    finally:
        ROOT = original
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> None:
    if "--self-test" in sys.argv[1:]:
        self_test()
        return
    failures = gate()
    if failures:
        sys.stderr.write("hotspot gate failed:\n")
        for line in failures:
            sys.stderr.write(f"  {line}\n")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
