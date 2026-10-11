#!/usr/bin/env bash
# Proves a killed PIT export passes, and a survivor, an uncovered mutant,
# or an empty export fails. Does not run PIT. There is no ceiling to raise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/pit-mutation.sh"
CHECK="${ROOT}/scripts/pit_mutation.py"
WORKFLOW="${ROOT}/.github/workflows/mutation.yml"
POM="${ROOT}/pom.xml"
RESULT="${ROOT}/src/main/java/com/embabel/guide/rag/IngestionResult.java"
FAILURE="${ROOT}/src/main/java/com/embabel/guide/rag/IngestionFailure.java"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"
[[ -f "${CHECK}" ]] || fail "missing ${CHECK}"
[[ -f "${WORKFLOW}" ]] || fail "missing ${WORKFLOW}"
[[ -f "${RESULT}" ]] || fail "missing ${RESULT}"
[[ -f "${FAILURE}" ]] || fail "missing ${FAILURE}"

if ! grep -qE '^[[:space:]]*pit:[[:space:]]*$' "${WORKFLOW}"; then
  fail "workflow must define job pit"
fi
if ! grep -q 'org.pitest:pitest-maven:mutationCoverage' "${WORKFLOW}" "${SCRIPT}"; then
  fail "workflow must run PIT mutationCoverage"
fi
if grep -q 'skipTests' "${SCRIPT}" "${WORKFLOW}"; then
  fail "PIT must not be skipped with skipTests"
fi
if ! grep -q 'pit-mutation-assert.sh' "${WORKFLOW}"; then
  fail "workflow must invoke this assert"
fi
if ! grep -q 'pit_mutation.py' "${WORKFLOW}" "${SCRIPT}"; then
  fail "workflow must require every mutant killed"
fi
if grep -q 'continue-on-error' "${WORKFLOW}"; then
  fail "mutation job must not continue-on-error"
fi
if grep -qE 'detekt-baseline|spotbugs-baseline|create-baseline' "${WORKFLOW}" "${SCRIPT}" "${CHECK}"; then
  fail "mutation job must not refresh the detekt or SpotBugs baseline"
fi
if ! grep -q '<mutationThreshold>100</mutationThreshold>' "${POM}"; then
  fail "mutation threshold must stay at 100"
fi
if [[ "$(grep -c '<mutationThreshold>' "${POM}")" -ne 1 ]]; then
  fail "pom must contain one mutation threshold"
fi
if ! grep -q '<failWhenNoMutations>true</failWhenNoMutations>' "${POM}"; then
  fail "an empty PIT run must fail"
fi
if ! grep -q 'com.embabel.guide.rag.IngestionResult' "${POM}"; then
  fail "PIT must target IngestionResult"
fi
if ! grep -q 'com.embabel.guide.rag.IngestionFailure' "${POM}"; then
  fail "PIT must target IngestionFailure"
fi
if ! grep -q '<artifactId>guide</artifactId>' "${POM}"; then
  fail "PIT must run on this module"
fi
if ! grep -q '||' "${RESULT}"; then
  fail "IngestionResult has nothing to mutate"
fi
if ! grep -q 'isBlank' "${FAILURE}"; then
  fail "IngestionFailure has nothing to mutate"
fi
if grep -qE 'boolean equals\(|int hashCode\(|String toString\(' "${RESULT}" "${FAILURE}"; then
  fail "hand-written equals, hashCode, or toString must not be excluded"
fi

echo "== proving: refuses-ceiling =="
if "${SCRIPT}" --ceiling >/tmp/pit-mutation-assert-out.txt 2>/tmp/pit-mutation-assert-err.txt; then
  fail "ceiling flag must fail"
fi
if ! grep -q 'refusing to raise the mutation ceiling' /tmp/pit-mutation-assert-err.txt; then
  fail "ceiling refusal must name the ceiling"
fi
if python3 "${CHECK}" --ceiling >/tmp/pit-mutation-assert-out.txt 2>/tmp/pit-mutation-assert-err.txt; then
  fail "checker must refuse --ceiling"
fi
if ! grep -q 'refusing to raise the mutation ceiling' /tmp/pit-mutation-assert-err.txt; then
  fail "checker ceiling refusal must name the ceiling"
fi
echo "refuses-ceiling OK"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
REPORT="${TMP}/mutations.xml"

write_report() {
  cat > "${REPORT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mutations>
$1
</mutations>
EOF
}

killed_row() {
  echo "<mutation detected='true' status='KILLED' numberOfTestsRun='2'><sourceFile>IngestionResult.java</sourceFile><mutatedClass>com.embabel.guide.rag.IngestionResult</mutatedClass><mutatedMethod>totalUrls</mutatedMethod><description>Replaced integer addition with subtraction</description></mutation>"
}

expect_fail() {
  local label="$1"
  if python3 "${CHECK}" --report "${REPORT}"; then
    fail "expected FAIL: ${label}"
  fi
}

write_report "$(killed_row)"
if ! python3 "${CHECK}" --report "${REPORT}"; then
  fail "killed export must pass"
fi

write_report "$(killed_row)
<mutation detected='false' status='SURVIVED' numberOfTestsRun='2'><mutatedMethod>hasFailures</mutatedMethod><description>negated conditional</description></mutation>"
expect_fail "survived mutant"

write_report "<mutation detected='false' status='NO_COVERAGE' numberOfTestsRun='0'><mutatedMethod>fromException</mutatedMethod></mutation>"
expect_fail "uncovered mutant"

write_report ""
expect_fail "empty export"

if python3 "${CHECK}" --report "${TMP}/missing.xml"; then
  fail "missing report must fail"
fi

echo "pit-mutation-assert OK"
