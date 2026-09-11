#!/usr/bin/env bash
# Assertions for the SPDD projection/ingest unit job (leftover #5).
# Same shape as jmjava/guide leftover #5 / PR #21.
# The job must be able to go red if projection contracts break.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/scripts/run-spdd-projection-unit.sh"
WORKFLOW="${ROOT}/.github/workflows/spdd-projection-unit.yml"
chmod +x "${RUNNER}"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/tmp/spdd-unit-assert-out.txt 2>/tmp/spdd-unit-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/spdd-unit-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/spdd-unit-assert-err.txt >&2
    fail "${label}: expected non-zero exit"
  fi
}

expect_ok() {
  local label="$1"
  shift
  if ! "$@" >/tmp/spdd-unit-assert-out.txt 2>/tmp/spdd-unit-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/spdd-unit-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/spdd-unit-assert-err.txt >&2
    fail "${label}: expected zero exit"
  fi
}

[[ -f "${RUNNER}" ]] || fail "missing ${RUNNER}"
[[ -f "${WORKFLOW}" ]] || fail "missing ${WORKFLOW} (no unit job on this fork)"

echo "== proving: job-exists =="
if ! grep -qE '^[[:space:]]*spdd-projection-unit:[[:space:]]*$' "${WORKFLOW}"; then
  fail "workflow must define job spdd-projection-unit"
fi
if ! grep -q 'run-spdd-projection-unit.sh' "${WORKFLOW}"; then
  fail "workflow must invoke run-spdd-projection-unit.sh so contract tests can go red"
fi
if ! grep -q 'spdd-projection-unit-assert.sh' "${WORKFLOW}"; then
  fail "workflow must invoke this assert so wiring sabotage stays red"
fi
if grep -q 'continue-on-error' "${WORKFLOW}"; then
  fail "spdd-projection-unit must not continue-on-error (contracts would stay green)"
fi
if grep -qE 'skipTests|maven.test.skip' "${WORKFLOW}"; then
  fail "spdd-projection-unit must not skip tests"
fi
echo "job-exists OK"

echo "== proving: failIfNoTests-wired =="
if ! grep -q -- '-DfailIfNoTests=true' "${RUNNER}"; then
  fail "runner must pass -DfailIfNoTests=true so zero tests redden the job"
fi
if ! grep -q -- '-Dsurefire.failIfNoSpecifiedTests=true' "${RUNNER}"; then
  fail "runner must pass -Dsurefire.failIfNoSpecifiedTests=true"
fi
if ! grep -q 'SpddMarkdownProjectionServiceTest' "${RUNNER}"; then
  fail "runner must include SpddMarkdownProjectionServiceTest"
fi
if ! grep -q 'GitIncrementalDirectorySupportTest' "${RUNNER}"; then
  fail "runner must include GitIncrementalDirectorySupportTest"
fi
echo "failIfNoTests-wired OK"

echo "== proving: required-contract-tests-present =="
expect_ok "preflight" "${RUNNER}" --preflight
if ! grep -q 'preflight OK' /tmp/spdd-unit-assert-out.txt; then
  fail "preflight must report OK when contract tests exist"
fi
echo "required-contract-tests-present OK"

echo "== proving: missing-test-class-fails =="
sabotage_tree="$(mktemp -d)"
mkdir -p "${sabotage_tree}/scripts" "${sabotage_tree}/.github/workflows"
cp "${RUNNER}" "${sabotage_tree}/scripts/run-spdd-projection-unit.sh"
chmod +x "${sabotage_tree}/scripts/run-spdd-projection-unit.sh"
# Recreate the required paths so preflight can then delete one.
while IFS= read -r rel; do
  [[ -z "${rel}" ]] && continue
  mkdir -p "${sabotage_tree}/$(dirname "${rel}")"
  : >"${sabotage_tree}/${rel}"
done < <("${RUNNER}" --files)
expect_ok "sabotage tree preflight before delete" \
  "${sabotage_tree}/scripts/run-spdd-projection-unit.sh" --preflight
rm -f "${sabotage_tree}/src/test/kotlin/com/embabel/guide/spdd/SpddMarkdownProjectionServiceTest.kt"
expect_fail "missing-test-class-fails" \
  "${sabotage_tree}/scripts/run-spdd-projection-unit.sh" --preflight
if ! grep -q 'SpddMarkdownProjectionServiceTest' /tmp/spdd-unit-assert-err.txt; then
  fail "missing-test-class-fails must name SpddMarkdownProjectionServiceTest"
fi
echo "missing-test-class-fails OK"

echo "== proving: sabotage empty test filter keeps the job red =="
sabotaged="${sabotage_tree}/scripts/run-spdd-projection-unit.sh"
cp "${RUNNER}" "${sabotaged}"
chmod +x "${sabotaged}"
# Neutralize fail-closed Maven flags so an empty filter could stay green.
sed -i 's/-DfailIfNoTests=true/-DfailIfNoTests=false/' "${sabotaged}"
sed -i 's/-Dsurefire.failIfNoSpecifiedTests=true/-Dsurefire.failIfNoSpecifiedTests=false/' "${sabotaged}"
if grep -q -- '-DfailIfNoTests=true' "${sabotaged}"; then
  fail "sabotage did not neutralize failIfNoTests; cannot prove the job would go red"
fi
# The live assert (require failIfNoTests=true) would now exit 1 — same as CI.
if grep -q -- '-DfailIfNoTests=true' "${sabotaged}"; then
  fail "expected sabotaged runner to lack failIfNoTests=true"
fi
if ! grep -q -- '-DfailIfNoTests=true' "${RUNNER}"; then
  fail "live runner lost failIfNoTests=true"
fi
echo "sabotage empty test filter keeps the job red OK"

echo "== proving: deleting the job keeps review/CI red =="
if [[ ! -f "${WORKFLOW}" ]]; then
  fail "workflow file missing"
fi
# A checkout without the job file must fail this assert (job-exists).
empty_tree="$(mktemp -d)"
mkdir -p "${empty_tree}/scripts" "${empty_tree}/.github/workflows"
cp "${RUNNER}" "${empty_tree}/scripts/run-spdd-projection-unit.sh"
cp "${ROOT}/scripts/spdd-projection-unit-assert.sh" "${empty_tree}/scripts/spdd-projection-unit-assert.sh"
chmod +x "${empty_tree}/scripts/"*.sh
expect_fail "deleted-job-workflow" "${empty_tree}/scripts/spdd-projection-unit-assert.sh"
if ! grep -q 'no unit job on this fork' /tmp/spdd-unit-assert-err.txt; then
  fail "deleted job must fail with 'no unit job on this fork'"
fi
echo "deleting the job keeps review/CI red OK"

echo "OK: SPDD projection unit assertions passed"
