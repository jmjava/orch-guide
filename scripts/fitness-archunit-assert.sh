#!/usr/bin/env bash
# Wiring check for the projection push-URL fitness function.
# Dropping the job, the ArchUnit test, or the violator that must fail keeps this red.
# The test itself is what fails when projection code calls an embabel/guide push URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/fitness-archunit.yml"
SCRIPT="${ROOT}/scripts/fitness-archunit.sh"
TEST="${ROOT}/src/test/java/com/embabel/guide/arch/ProjectionPushUrlFitnessTest.java"
FIXTURES="${ROOT}/src/test/java/com/embabel/guide/spdd/ProjectionPushUrlFixtures.java"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

[[ -f "${WORKFLOW}" ]] || fail "missing ${WORKFLOW}"
[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"
[[ -f "${TEST}" ]] || fail "missing ${TEST}"
[[ -f "${FIXTURES}" ]] || fail "missing ${FIXTURES}"

if ! grep -qE '^[[:space:]]*fitness-archunit:[[:space:]]*$' "${WORKFLOW}"; then
  fail "workflow must define job fitness-archunit"
fi
if ! grep -q 'fitness-archunit.sh' "${WORKFLOW}"; then
  fail "workflow must invoke fitness-archunit.sh"
fi
if ! grep -q 'fitness-archunit-assert.sh' "${WORKFLOW}"; then
  fail "workflow must invoke this assert so dropping the job stays red"
fi
if grep -q 'continue-on-error' "${WORKFLOW}"; then
  fail "fitness-archunit must not continue-on-error"
fi
if grep -qE 'detekt-baseline|spotbugs|pitest|mutmut' "${WORKFLOW}"; then
  fail "fitness workflow must not add a baseline or mutation tool"
fi

if ! grep -q 'ClassFileImporter' "${TEST}"; then
  fail "fitness test must import classes with ArchUnit"
fi
if ! grep -q 'com.embabel.guide.spdd..' "${TEST}"; then
  fail "fitness rule must select the projection package"
fi
if ! grep -q 'assertThrows' "${TEST}"; then
  fail "fitness test must show the rule can fail"
fi
if ! grep -q 'ProjectionPushUrlFixtures.Direct' "${TEST}"; then
  fail "fitness test must check a projection class that calls a push URL"
fi
if ! grep -q 'ProjectionPushUrlFixtures.Mention' "${TEST}"; then
  fail "fitness test must allow a mention that is not a call"
fi
if ! grep -q 'CallsEmbabelGuidePushUrlOutsideProjection' "${TEST}"; then
  fail "fitness test must ignore the same call outside the projection package"
fi
if ! grep -q 'SpddMarkdownProjectionService' "${TEST}"; then
  fail "fitness test must check production projection classes"
fi
if ! grep -q 'DO_NOT_INCLUDE_TESTS' "${TEST}"; then
  fail "production import must skip test fixtures"
fi

if ! grep -q 'https://github.com/embabel/guide.git' "${FIXTURES}"; then
  fail "violator fixture must call the embabel/guide push URL"
fi
if ! grep -q 'https://github.com/jmjava/orch-guide.git' "${FIXTURES}"; then
  fail "fork fixture must call the jmjava/orch-guide URL"
fi
if ! grep -q 'https://github.com/jmjava/guide.git' "${FIXTURES}"; then
  fail "fork fixture must call the jmjava/guide URL"
fi

if ! grep -q 'ProjectionPushUrlFitnessTest' "${SCRIPT}"; then
  fail "runner must execute ProjectionPushUrlFitnessTest"
fi
if ! grep -q 'failIfNoTests=true' "${SCRIPT}"; then
  fail "runner must fail when the fitness test is filtered out"
fi
if ! grep -q 'surefire.failIfNoSpecifiedTests=true' "${SCRIPT}"; then
  fail "runner must fail when surefire skips the fitness test"
fi

echo "fitness-archunit assert OK"
