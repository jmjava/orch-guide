#!/usr/bin/env bash
# Detekt ratchets:
#   cayc      — Clean as You Code: fail on new findings that sit on changed lines
#   baseline  — full Kotlin tree; fail on a finding that is not in the frozen baseline
#
# Old findings are printed from the frozen baseline. This script never writes
# config/detekt/baseline.xml. --create-baseline is refused.
set -euo pipefail

ROOT="${RATCHET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

for arg in "$@"; do
  case "$arg" in
    --create-baseline|--write-baseline|-cb)
      echo "refusing to rewrite the detekt baseline" >&2
      exit 1
      ;;
  esac
done

MODE="${1:-}"
if [[ "$MODE" != "cayc" && "$MODE" != "baseline" ]]; then
  echo "usage: $0 cayc|baseline" >&2
  exit 2
fi

VERSION="2.0.0-alpha.3"
SHA="dc71f1eb705fa87abac0d63a5ebb51868d6a6e64bc96eaf56cd2c2a889d2491d"
URL="https://github.com/detekt/detekt/releases/download/v${VERSION}/detekt-cli-${VERSION}-all.jar"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/detekt"
JAR="${CACHE}/detekt-cli-${VERSION}-all.jar"
BASELINE="${RATCHET_BASELINE:-${ROOT}/config/detekt/baseline.xml}"
BASE_REF="${RATCHET_BASE:-origin/main}"
REPORT="${ROOT}/target/detekt-${MODE}.xml"

if [[ ! -f "$BASELINE" ]]; then
  echo "missing detekt baseline: ${BASELINE}" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  echo "${BASE_REF} is required" >&2
  exit 1
fi

mkdir -p "$CACHE"
if [[ ! -f "$JAR" ]]; then
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$URL"
  echo "${SHA}  ${tmp}" | sha256sum -c -
  mv "$tmp" "$JAR"
fi

print_old_findings() {
  echo "=== frozen baseline findings (visible; baseline is not rewritten) ==="
  grep -E '<ID>' "$BASELINE" || true
}

run_detekt() {
  local input="$1"
  local severity="$2"
  mkdir -p "$(dirname "$REPORT")"
  java -jar "$JAR" \
    --input "$input" \
    --baseline "$BASELINE" \
    --base-path "$ROOT" \
    --language-version 2.3 \
    --jvm-target 21 \
    --build-upon-default-config \
    --excludes '**/build/**,**/.gradle/**' \
    --fail-on-severity "$severity" \
    --report "checkstyle:${REPORT}"
}

print_old_findings

if [[ "$MODE" == "baseline" ]]; then
  set +e
  run_detekt "src/main/kotlin:src/test/kotlin" Info
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "detekt baseline: new findings are not in the frozen baseline" >&2
    exit "$status"
  fi
  echo "detekt baseline: no new findings"
  exit 0
fi

mapfile -t files < <(
  {
    git diff --name-only --diff-filter=ACMR "${BASE_REF}...HEAD"
    git diff --name-only --diff-filter=ACMR
    git diff --name-only --diff-filter=ACMR --cached
    git ls-files --others --exclude-standard
  } | awk 'NF && $0 ~ /^src\/.*\.kt$/ { print }' | sort -u
)

existing=()
if [[ ${#files[@]} -gt 0 ]]; then
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      existing+=("$f")
    fi
  done
fi

if [[ ${#existing[@]} -eq 0 ]]; then
  echo "detekt clean-as-you-code: no Kotlin changes versus ${BASE_REF}"
  exit 0
fi

line_file="$(mktemp)"
trap 'rm -f "$line_file"' EXIT
python3 - "$ROOT" "$BASE_REF" "$line_file" <<'PY'
import os
import subprocess
import sys

root, base, dest = sys.argv[1:4]


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode or 1)
    return result.stdout


def parse(diff: str, acc: dict[str, set[int]]) -> None:
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            if path == "/dev/null":
                path = None
            continue
        if path is None or not line.startswith("@@"):
            continue
        plus = line.split(" ")[2][1:]
        if "," in plus:
            start_s, count_s = plus.split(",", 1)
            start, count = int(start_s), int(count_s)
        else:
            start, count = int(plus), 1
        if count <= 0:
            continue
        acc.setdefault(path, set()).update(range(start, start + count))


acc: dict[str, set[int]] = {}
parse(git("diff", "-U0", "--diff-filter=ACMR", f"{base}...HEAD"), acc)
parse(git("diff", "-U0", "--diff-filter=ACMR"), acc)
parse(git("diff", "-U0", "--diff-filter=ACMR", "--cached"), acc)
for rel in git("ls-files", "--others", "--exclude-standard").splitlines():
    rel = rel.strip()
    if not rel.endswith(".kt"):
        continue
    full = os.path.join(root, rel)
    if not os.path.isfile(full):
        continue
    with open(full, encoding="utf-8", errors="replace") as handle:
        count = sum(1 for _ in handle)
    if count:
        acc.setdefault(rel, set()).update(range(1, count + 1))

with open(dest, "w", encoding="utf-8") as handle:
    for path in sorted(acc):
        for line_no in sorted(acc[path]):
            handle.write(f"{path} {line_no}\n")
PY

input="$(IFS=:; echo "${existing[*]}")"
echo "detekt clean-as-you-code: ${existing[*]}"
set +e
run_detekt "$input" Never
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  echo "detekt failed to analyze changed Kotlin" >&2
  exit "$status"
fi

python3 - "$ROOT" "$REPORT" "$line_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

root, report, line_file = sys.argv[1:4]
changed: dict[str, set[int]] = {}
with open(line_file, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        path, line_s = raw.rsplit(" ", 1)
        changed.setdefault(path, set()).add(int(line_s))

try:
    tree = ET.parse(report)
except FileNotFoundError:
    print("detekt clean-as-you-code: no new findings on changed lines")
    raise SystemExit(0)

gated: list[str] = []
printed: list[str] = []
for file_el in tree.getroot().findall("file"):
    name = file_el.get("name") or ""
    rel = name
    prefix = root.rstrip("/") + "/"
    if rel.startswith(prefix):
        rel = rel[len(prefix):]
    lines = changed.get(rel)
    if lines is None:
        lines = changed.get(name)
    for err in file_el.findall("error"):
        line = int(err.get("line") or "0")
        source = err.get("source") or "detekt"
        message = err.get("message") or "finding"
        text = f"{rel}:{line}: {source}: {message}"
        printed.append(text)
        if lines is None or line in lines:
            gated.append(text)

if printed:
    print("=== new detekt findings (not in the frozen baseline) ===")
    for text in printed:
        print(text)
if gated:
    sys.stderr.write("clean-as-you-code failed on changed lines:\n")
    for text in gated:
        sys.stderr.write(f"  {text}\n")
    raise SystemExit(1)
print("detekt clean-as-you-code: no new findings on changed lines")
PY
