#!/usr/bin/env bash
# Clean as You Code: fail when a finding lands on a changed Kotlin or Java line.
# Detekt rates Kotlin. Checkstyle rates Java, because detekt does not parse Java.
# Findings on unchanged lines are printed and do not fail the run.
# Does not write or refresh a baseline.
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    --create-baseline|--write-baseline|-cb)
      echo "refusing to rewrite the detekt baseline" >&2
      exit 1
      ;;
    -h|--help)
      echo "usage: $0" >&2
      echo "Rates Kotlin and Java lines changed versus DETEKT_BASE (default: origin/main)." >&2
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

ROOT="${DETEKT_CAYC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_CONFIG="${SCRIPT_DIR}/detekt-cayc-java.xml"
cd "$ROOT"

DETEKT_VERSION="2.0.0-alpha.3"
DETEKT_SHA="dc71f1eb705fa87abac0d63a5ebb51868d6a6e64bc96eaf56cd2c2a889d2491d"
DETEKT_URL="https://github.com/detekt/detekt/releases/download/v${DETEKT_VERSION}/detekt-cli-${DETEKT_VERSION}-all.jar"
CHECKSTYLE_VERSION="10.26.1"
CHECKSTYLE_SHA="e41c24433723ba310a30e41da4f449c105ad47cab2ae9e6be5e06606a647dbca"
CHECKSTYLE_URL="https://github.com/checkstyle/checkstyle/releases/download/checkstyle-${CHECKSTYLE_VERSION}/checkstyle-${CHECKSTYLE_VERSION}-all.jar"
CACHE="${DETEKT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/detekt}"
DETEKT_JAR="${CACHE}/detekt-cli-${DETEKT_VERSION}-all.jar"
CHECKSTYLE_JAR="${CACHE}/checkstyle-${CHECKSTYLE_VERSION}-all.jar"
BASE_REF="${DETEKT_BASE:-origin/main}"
LANGUAGE_VERSION="${DETEKT_LANGUAGE_VERSION:-2.3}"

if [[ ! -f "$JAVA_CONFIG" ]]; then
  echo "detekt clean-as-you-code: java ruleset is missing: ${JAVA_CONFIG}" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null; then
  echo "detekt clean-as-you-code: base ref ${BASE_REF} is missing" >&2
  exit 1
fi

fetch_jar() {
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]] && echo "${sha}  ${dest}" | sha256sum -c - >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$url"
  echo "${sha}  ${tmp}" | sha256sum -c -
  mv "$tmp" "$dest"
}

mapfile -t files < <(
  {
    git diff --name-only --diff-filter=ACMR "${BASE_REF}...HEAD"
    git diff --name-only --diff-filter=ACMR
    git diff --name-only --diff-filter=ACMR --cached
    git ls-files --others --exclude-standard
  } | awk 'NF && $0 ~ /(^|\/)src\/.*\.(kt|java)$/ && $0 !~ /\.\./ { print }' | sort -u
)

kotlin=()
java=()
if [[ ${#files[@]} -gt 0 ]]; then
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      continue
    fi
    case "$f" in
      *.kt) kotlin+=("$f") ;;
      *.java) java+=("$f") ;;
    esac
  done
fi

if [[ ${#kotlin[@]} -eq 0 && ${#java[@]} -eq 0 ]]; then
  echo "detekt clean-as-you-code: no Kotlin or Java changes versus ${BASE_REF}"
  exit 0
fi

line_file="$(mktemp)"
kt_report="$(mktemp)"
java_report="$(mktemp)"
trap 'rm -f "$line_file" "$kt_report" "$java_report"' EXIT

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


def gated_src(path: str) -> bool:
    if ".." in path.split("/"):
        return False
    if not (path.endswith(".kt") or path.endswith(".java")):
        return False
    return path.startswith("src/") or "/src/" in path


def parse(diff: str, acc: dict[str, set[int]]) -> None:
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            if path == "/dev/null" or not gated_src(path):
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
    if not gated_src(rel):
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

reports=()
if [[ ${#kotlin[@]} -gt 0 ]]; then
  fetch_jar "$DETEKT_URL" "$DETEKT_JAR" "$DETEKT_SHA"
  input="$(IFS=:; echo "${kotlin[*]}")"
  echo "detekt clean-as-you-code: kotlin ${kotlin[*]}"
  set +e
  java -jar "$DETEKT_JAR" \
    --input "$input" \
    --base-path "$ROOT" \
    --language-version "$LANGUAGE_VERSION" \
    --jvm-target 21 \
    --build-upon-default-config \
    --excludes '**/build/**,**/.gradle/**,**/target/**' \
    --fail-on-severity Never \
    --report "checkstyle:${kt_report}"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "detekt failed to analyze changed Kotlin" >&2
    exit "$status"
  fi
  reports+=("$kt_report")
fi

if [[ ${#java[@]} -gt 0 ]]; then
  fetch_jar "$CHECKSTYLE_URL" "$CHECKSTYLE_JAR" "$CHECKSTYLE_SHA"
  echo "detekt clean-as-you-code: java ${java[*]}"
  set +e
  java -jar "$CHECKSTYLE_JAR" \
    -c "$JAVA_CONFIG" \
    -f xml \
    -o "$java_report" \
    "${java[@]}"
  status=$?
  set -e
  if [[ ! -s "$java_report" ]] || ! head -n 1 "$java_report" | grep -q '<\?xml'; then
    echo "checkstyle failed to analyze changed Java" >&2
    exit "${status:-1}"
  fi
  reports+=("$java_report")
fi

python3 - "$ROOT" "$line_file" "${reports[@]}" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
line_file = sys.argv[2]
reports = sys.argv[3:]
changed: dict[str, set[int]] = {}
with open(line_file, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw:
            continue
        path, line_s = raw.rsplit(" ", 1)
        changed.setdefault(path, set()).add(int(line_s))

visible: list[str] = []
gated: list[str] = []
for report in reports:
    try:
        tree = ET.parse(report)
    except (ET.ParseError, FileNotFoundError) as exc:
        sys.stderr.write(f"unreadable report {report}: {exc}\n")
        raise SystemExit(1)
    for file_el in tree.getroot().findall("file"):
        name = file_el.get("name") or ""
        rel = name
        prefix = root.rstrip("/") + "/"
        if rel.startswith(prefix):
            rel = rel[len(prefix):]
        lines = changed.get(rel)
        if lines is None:
            lines = changed.get(name)
        full = rel if os.path.isabs(rel) else os.path.join(root, rel)
        file_len = 0
        if os.path.isfile(full):
            with open(full, encoding="utf-8", errors="replace") as handle:
                file_len = sum(1 for _ in handle)
        whole_file = bool(lines) and file_len > 0 and lines >= set(range(1, file_len + 1))
        for err in file_el.findall("error"):
            line = int(err.get("line") or "0")
            source = err.get("source") or "detekt"
            message = err.get("message") or "finding"
            text = f"{rel}:{line}: {source}: {message}"
            on_changed_line = lines is not None and line in lines
            file_level_on_new_file = line <= 0 and whole_file
            if lines is None or on_changed_line or file_level_on_new_file:
                gated.append(text)
            else:
                visible.append(text)

if visible:
    print("=== detekt findings outside changed lines (visible; not a failure) ===")
    for text in visible:
        print(text)
if gated:
    sys.stderr.write("clean-as-you-code failed on changed lines:\n")
    for text in gated:
        sys.stderr.write(f"  {text}\n")
    raise SystemExit(1)
print("detekt clean-as-you-code: no findings on changed lines")
PY
