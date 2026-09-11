#!/usr/bin/env bash
# Run fork-local SPDD projection + git-incremental ingest unit tests.
# Fail-closed: missing classes or zero matching tests redden CI.
# Leftover #5 — same shape as jmjava/guide leftover #5 / PR #21.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Leftover #5: these classes are the projection/ingest contract.
# Deleting one must keep the spdd-projection-unit job red.
REQUIRED_TEST_FILES=(
  "src/test/kotlin/com/embabel/guide/spdd/SpddMarkdownProjectionServiceTest.kt"
  "src/test/kotlin/com/embabel/guide/spdd/SpddProjectionControllerTest.kt"
  "src/test/kotlin/com/embabel/guide/spdd/SpddDomainToolsTest.kt"
  "src/test/java/com/embabel/guide/rag/GitIncrementalDirectorySupportTest.java"
  "src/test/kotlin/com/embabel/guide/rag/IngestionRunnerTest.kt"
  "src/test/kotlin/com/embabel/guide/rag/IngestionResultTest.kt"
  "src/test/kotlin/com/embabel/guide/rag/IngestionFailureTest.kt"
)

fail() {
  echo "FORBIDDEN: $*" >&2
  exit 1
}

class_name_from_file() {
  local path="$1"
  local base
  base="$(basename "${path}")"
  echo "${base%.*}"
}

preflight() {
  local missing=0
  local f
  for f in "${REQUIRED_TEST_FILES[@]}"; do
    if [[ ! -f "${ROOT}/${f}" ]]; then
      echo "FORBIDDEN: missing SPDD projection/ingest unit test ${f}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
  echo "preflight OK: ${#REQUIRED_TEST_FILES[@]} projection/ingest unit test files present"
}

test_csv() {
  local names=()
  local f
  for f in "${REQUIRED_TEST_FILES[@]}"; do
    names+=("$(class_name_from_file "${f}")")
  done
  local IFS=','
  echo "${names[*]}"
}

usage() {
  cat <<'EOF'
Usage: run-spdd-projection-unit.sh [--preflight|--list|--files]
  (default)  preflight, then mvn test on projection/ingest classes
  --preflight  fail if a required test file is missing (no Maven)
  --list       print required class names (comma-separated)
  --files      print required test file paths (one per line)
EOF
}

mode="${1:-}"
case "${mode}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    test_csv
    exit 0
    ;;
  --files)
    printf '%s\n' "${REQUIRED_TEST_FILES[@]}"
    exit 0
    ;;
  --preflight)
    preflight
    exit 0
    ;;
  "")
    ;;
  *)
    fail "unknown argument: ${mode}"
    ;;
esac

preflight

csv="$(test_csv)"
echo "Running SPDD projection/ingest unit tests: ${csv}"
# failIfNoTests keeps the job red if the filter matches nothing
# (deleted/renamed contract tests, empty -Dtest, or surefire skip).
exec mvn -U -B test \
  "-Dtest=${csv}" \
  -DfailIfNoTests=true \
  -Dsurefire.failIfNoSpecifiedTests=true
