#!/usr/bin/env bash
# OGD-06: export-seed must not package with -DskipTests.
# A broken seed must fail the job before any upload.
# This script does not start Neo4j and does not upload a seed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: assert-export-seed-runs-tests.sh [--self-test]

  (default)  Fail if .github/workflows/export-seed.yml packages with
             -DskipTests or -Dmaven.test.skip, or if that check is not
             ordered before the package command and the seed upload.
             EXPORT_SEED_WORKFLOW overrides the workflow path.
  --self-test
             Prove the live workflow passes, and that putting -DskipTests
             back on the package line fails. A comment that merely mentions
             the flag still passes.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_WORKFLOW="${ROOT}/.github/workflows/export-seed.yml"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

# Maven package command text with comments and backslash continuations joined.
package_commands() {
  local file="$1"
  local acc=0
  local buf=""
  local line code

  while IFS= read -r line || [[ -n "${line}" ]]; do
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "${trimmed}" || "${trimmed}" == \#* ]]; then
      continue
    fi
    code="${line%%#*}"
    code="${code%"${code##*[![:space:]]}"}"
    if [[ "${acc}" -eq 1 ]]; then
      if [[ "${code}" == *\\ ]]; then
        buf+=" ${code%\\}"
        continue
      fi
      buf+=" ${code}"
      acc=0
      printf '%s\n' "${buf}"
      buf=""
      continue
    fi
    if [[ "${code}" == *\\ && "${code}" =~ mvn ]]; then
      acc=1
      buf="${code%\\}"
      continue
    fi
    if [[ "${code}" =~ mvn ]]; then
      printf '%s\n' "${code}"
    fi
  done <"${file}"
}

is_package_command() {
  local cmd="$1"
  [[ "${cmd}" =~ (^|[^[:alnum:]_])mvnw?([^[:alnum:]_]|$) ]] || return 1
  [[ "${cmd}" =~ (^|[[:space:]])package([[:space:]]|$) ]]
}

assert_workflow() {
  local file="$1"
  local cmd found=0
  local assert_line="" package_line="" upload_line=""

  [[ -f "${file}" ]] || fail "missing export-seed workflow ${file}"

  if grep -qE '^[[:space:]]*continue-on-error[[:space:]]*:' "${file}"; then
    fail "export-seed must not set continue-on-error (a skipped-test package would stay green)"
  fi

  while IFS= read -r hit; do
    local num="${hit%%:*}"
    local text="${hit#*:}"
    local trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "${trimmed}" == \#* ]] && continue
    if [[ -z "${assert_line}" && "${text}" == *assert-export-seed-runs-tests.sh* ]]; then
      assert_line="${num}"
    fi
    if [[ -z "${package_line}" ]] && is_package_command "${text}"; then
      package_line="${num}"
    fi
    if [[ -z "${upload_line}" && "${text}" == *upload-artifact* ]]; then
      upload_line="${num}"
    fi
  done < <(grep -n '' "${file}")

  [[ -n "${assert_line}" ]] || fail "export-seed must invoke assert-export-seed-runs-tests.sh before upload"
  [[ -n "${package_line}" ]] || fail "export-seed workflow has no mvn package command"
  [[ -n "${upload_line}" ]] || fail "export-seed workflow is missing the seed upload step"
  [[ "${assert_line}" -lt "${package_line}" ]] || fail "assert must run before the mvn package line"
  [[ "${assert_line}" -lt "${upload_line}" ]] || fail "assert must run before the seed upload"

  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    is_package_command "${cmd}" || continue
    found=1
    if [[ "${cmd}" == *-DskipTests* || "${cmd}" == *-Dmaven.test.skip* ]]; then
      fail "export-seed package line skips tests: ${cmd}"
    fi
  done < <(package_commands "${file}")

  [[ "${found}" -ge 1 ]] || fail "export-seed workflow has no mvn package command"
}

self_test() {
  local tmp live_copy
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  echo "== proving: live package line runs tests =="
  assert_workflow "${DEFAULT_WORKFLOW}"
  echo "live-package-runs-tests OK"

  live_copy="${tmp}/export-seed.yml"
  cp "${DEFAULT_WORKFLOW}" "${live_copy}"

  echo "== proving: -DskipTests on the package line fails =="
  sed 's/mvn -U -B package/mvn -U -B package -DskipTests/' "${DEFAULT_WORKFLOW}" >"${tmp}/skip.yml"
  if EXPORT_SEED_WORKFLOW="${tmp}/skip.yml" "$0" >"${tmp}/out" 2>"${tmp}/err"; then
    fail "skipTests-on-package-line-fails: expected non-zero exit"
  fi
  if ! grep -q 'skips tests' "${tmp}/err"; then
    cat "${tmp}/err" >&2
    fail "skipTests-on-package-line-fails: expected 'skips tests'"
  fi
  echo "skipTests-on-package-line-fails OK"

  echo "== proving: -DskipTests before the package goal fails =="
  sed 's/mvn -U -B package/mvn -DskipTests -U -B package/' "${DEFAULT_WORKFLOW}" >"${tmp}/before.yml"
  if EXPORT_SEED_WORKFLOW="${tmp}/before.yml" "$0" >"${tmp}/out" 2>"${tmp}/err"; then
    fail "skipTests-before-package-fails: expected non-zero exit"
  fi
  echo "skipTests-before-package-fails OK"

  echo "== proving: continued -DskipTests on the package command fails =="
  awk '
    /mvn -U -B package/ && !done {
      print "        run: mvn -U -B package \\"
      print "          -DskipTests"
      done = 1
      next
    }
    { print }
  ' "${DEFAULT_WORKFLOW}" >"${tmp}/cont.yml"
  if EXPORT_SEED_WORKFLOW="${tmp}/cont.yml" "$0" >"${tmp}/out" 2>"${tmp}/err"; then
    fail "continued-skipTests-fails: expected non-zero exit"
  fi
  echo "continued-skipTests-fails OK"

  echo "== proving: a comment that mentions -DskipTests still passes =="
  cp "${DEFAULT_WORKFLOW}" "${tmp}/comment.yml"
  printf '\n# historical command was: mvn -U -B package -DskipTests\n' >>"${tmp}/comment.yml"
  EXPORT_SEED_WORKFLOW="${tmp}/comment.yml" "$0" >"${tmp}/out" 2>"${tmp}/err"
  echo "comment-mention-passes OK"

  echo "== proving: dropping the gate fails before upload can be reached =="
  grep -v 'assert-export-seed-runs-tests.sh' "${DEFAULT_WORKFLOW}" >"${tmp}/nogate.yml"
  if EXPORT_SEED_WORKFLOW="${tmp}/nogate.yml" "$0" >"${tmp}/out" 2>"${tmp}/err"; then
    fail "missing-gate-fails: expected non-zero exit"
  fi
  if ! grep -q 'before upload' "${tmp}/err"; then
    cat "${tmp}/err" >&2
    fail "missing-gate-fails: expected the upload-order failure"
  fi
  echo "missing-gate-fails OK"

  echo "export-seed test gate OK"
}

case "${1:-}" in
  --self-test) self_test ;;
  -h | --help) usage ;;
  "")
    assert_workflow "${EXPORT_SEED_WORKFLOW:-${DEFAULT_WORKFLOW}}"
    echo "export-seed package line runs tests"
    ;;
  *)
    usage >&2
    fail "unknown argument: ${1}"
    ;;
esac
