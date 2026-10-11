#!/usr/bin/env python3
"""Compare detekt and SpotBugs findings to a frozen fingerprint baseline.

A fingerprint already in the baseline is printed and does not fail the run.
A fingerprint that is absent, or a higher count of a known fingerprint, fails.
An empty baseline is not a pass. This module never writes a baseline file.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    fingerprint: str
    rule: str
    path: str
    message: str
    line: int


def detekt_fingerprint(path: str, rule: str, message: str) -> str:
    blob = f"{path}\0{rule}\0{message}".encode()
    return hashlib.sha256(blob).hexdigest()


def spotbugs_fingerprint(instance_hash: str) -> str:
    fingerprint = instance_hash.strip().lower()
    if not fingerprint:
        raise ValueError("SpotBugs finding is missing instanceHash")
    return fingerprint


def relativize(path: str, root: Path) -> str:
    text = path.replace("\\", "/")
    if text.startswith("./"):
        text = text[2:]
    candidate = Path(text)
    if candidate.is_absolute():
        try:
            text = candidate.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            text = candidate.as_posix()
    if text.startswith("main/java/") or text.startswith("test/java/"):
        text = "src/" + text
    return text


def parse_baseline(text: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            count_text, fingerprint, _rest = line.split(" ", 2)
            count = int(count_text)
        except ValueError as exc:
            raise ValueError(f"malformed baseline line: {line}") from exc
        if count < 1 or not fingerprint:
            raise ValueError(f"malformed baseline line: {line}")
        counts[fingerprint] = counts.get(fingerprint, 0) + count
    return counts


def render_baseline(scanner: str, findings: list[Finding]) -> str:
    if scanner == "detekt":
        header = (
            "# Frozen detekt fingerprints for Kotlin sources.\n"
            "# Old fingerprints stay visible and do not fail the build.\n"
            "# A new fingerprint, or a higher count, fails.\n"
            "# Do not refresh this file to hide a finding.\n"
            "# detekt 2.0.0-alpha.3, default config, language-version 2.3\n"
        )
    elif scanner == "spotbugs":
        header = (
            "# Frozen SpotBugs fingerprints for Java sources.\n"
            "# Old fingerprints stay visible and do not fail the build.\n"
            "# A new fingerprint, or a higher count, fails.\n"
            "# Do not refresh this file to hide a finding.\n"
            "# SpotBugs 4.9.3\n"
        )
    else:
        raise ValueError(f"unknown scanner: {scanner}")
    grouped: dict[str, list[Finding]] = {}
    for finding in findings:
        grouped.setdefault(finding.fingerprint, []).append(finding)
    lines = [header.rstrip("\n")]
    for fingerprint in sorted(grouped, key=lambda item: (grouped[item][0].path, grouped[item][0].rule, item)):
        sample = sorted(grouped[fingerprint], key=lambda item: (item.line, item.message))[0]
        lines.append(
            f"{len(grouped[fingerprint])} {fingerprint} {sample.rule} {sample.path} {sample.message}"
        )
    return "\n".join(lines) + "\n"


def load_detekt(report: Path, root: Path) -> list[Finding]:
    tree = ET.parse(report)
    findings: list[Finding] = []
    for file_el in tree.getroot().findall("file"):
        path = relativize(file_el.get("name") or "", root)
        for err in file_el.findall("error"):
            rule = err.get("source") or "detekt"
            message = err.get("message") or "finding"
            line = int(err.get("line") or "0")
            findings.append(
                Finding(
                    fingerprint=detekt_fingerprint(path, rule, message),
                    rule=rule,
                    path=path,
                    message=message,
                    line=line,
                )
            )
    return findings


def _spotbugs_source(bug: ET.Element) -> ET.Element | None:
    for source in bug.findall("SourceLine"):
        if source.get("primary") == "true":
            return source
    return bug.find("SourceLine")


def load_spotbugs(report: Path, root: Path) -> list[Finding]:
    tree = ET.parse(report)
    findings: list[Finding] = []
    for bug in tree.getroot().findall("BugInstance"):
        source = _spotbugs_source(bug)
        raw_path = ""
        line = 0
        if source is not None:
            raw_path = source.get("relSourcepath") or source.get("sourcepath") or ""
            line = int(source.get("start") or "0")
        path = relativize(raw_path, root) if raw_path else ""
        if not path:
            raise ValueError("SpotBugs finding is missing a source path")
        message_el = bug.find("LongMessage")
        message = (message_el.text or "").strip() if message_el is not None else ""
        if not message:
            message = bug.get("type") or "finding"
        rule = bug.get("type") or "SpotBugs"
        findings.append(
            Finding(
                fingerprint=spotbugs_fingerprint(bug.get("instanceHash") or ""),
                rule=rule,
                path=path,
                message=message,
                line=line,
            )
        )
    return findings


def compare(findings: list[Finding], baseline: dict[str, int]) -> tuple[list[str], list[str]]:
    grouped: dict[str, list[Finding]] = {}
    for finding in findings:
        grouped.setdefault(finding.fingerprint, []).append(finding)
    visible: list[str] = []
    failures: list[str] = []
    for fingerprint, group in sorted(grouped.items(), key=lambda item: (item[1][0].path, item[1][0].line, item[0])):
        group = sorted(group, key=lambda item: (item.line, item.message))
        allowed = baseline.get(fingerprint, 0)
        sample = group[0]
        if allowed < 1:
            for finding in group:
                failures.append(
                    f"NEW {finding.path}:{finding.line}: {finding.rule}: {finding.message}"
                )
            continue
        if len(group) > allowed:
            failures.append(
                f"NEW {sample.path} {sample.rule} count {allowed} -> {len(group)}: {sample.message}"
            )
        for finding in group[:allowed]:
            visible.append(f"{finding.path}:{finding.line}: {finding.rule}: {finding.message}")
    return visible, failures


def run_compare(scanner: str, baseline_path: Path, report: Path, root: Path) -> int:
    if not baseline_path.is_file():
        print(f"missing {scanner} baseline: {baseline_path}", file=sys.stderr)
        return 2
    try:
        baseline = parse_baseline(baseline_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 2
    if not baseline:
        print("empty baseline is not a pass", file=sys.stderr)
        return 1
    try:
        if scanner == "detekt":
            findings = load_detekt(report, root)
        elif scanner == "spotbugs":
            findings = load_spotbugs(report, root)
        else:
            print(f"unknown scanner: {scanner}", file=sys.stderr)
            return 2
    except (ET.ParseError, OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 2
    visible, failures = compare(findings, baseline)
    if visible:
        print(f"=== {scanner} findings in the baseline (visible; not a failure) ===")
        for line in visible:
            print(line)
    if failures:
        print(f"static baseline failed on new {scanner} findings:", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        return 1
    print(f"static baseline: {scanner} PASS ({len(findings)} finding(s), {len(baseline)} fingerprint(s))")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if any(arg in {"--create-baseline", "--write-baseline", "-cb"} for arg in argv):
        print("refusing to rewrite the static baseline", file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("compare",))
    parser.add_argument("--scanner", required=True, choices=("detekt", "spotbugs"))
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    return run_compare(args.scanner, args.baseline, args.report, args.root)


if __name__ == "__main__":
    raise SystemExit(main())
