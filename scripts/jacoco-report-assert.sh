#!/usr/bin/env bash
# A missing or empty JaCoCo XML must redden the Build job.
# The report step must not continue-on-error, and the follow-up scan must
# exit non-zero when target/site/jacoco/jacoco.xml is missing or empty.
# Codecov upload stays non-blocking (continue-on-error: true).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/maven.yml"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/tmp/jacoco-report-assert-out.txt 2>/tmp/jacoco-report-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/jacoco-report-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/jacoco-report-assert-err.txt >&2
    fail "${label}: expected non-zero exit"
  fi
}

expect_ok() {
  local label="$1"
  shift
  if ! "$@" >/tmp/jacoco-report-assert-out.txt 2>/tmp/jacoco-report-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/jacoco-report-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/jacoco-report-assert-err.txt >&2
    fail "${label}: expected zero exit"
  fi
}

# Print one GitHub Actions step block (starting at "      - name:" / "      - uses:").
extract_steps() {
  local wf="$1"
  local needle="$2"
  awk -v needle="$needle" '
    function flush() {
      if (block ~ needle) {
        printf "%s", block
        if (substr(block, length(block), 1) != "\n") printf "\n"
        printf "---STEP---\n"
      }
    }
    /^      - name:/ || /^      - uses:/ {
      if (block != "") flush()
      block = $0 "\n"
      next
    }
    block != "" {
      if ($0 ~ /^        / || $0 ~ /^      #/ || $0 ~ /^[[:space:]]*$/) {
        block = block $0 "\n"
        next
      }
      flush()
      block = ""
    }
    END { if (block != "") flush() }
  ' "${wf}"
}

check_report() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "missing jacoco report: ${path}" >&2
    return 1
  fi
  if [[ ! -s "${path}" ]]; then
    echo "empty jacoco report: ${path}" >&2
    return 1
  fi
  if ! grep -q '[^[:space:]]' "${path}"; then
    echo "empty jacoco report: ${path}" >&2
    return 1
  fi
  return 0
}

# Return non-zero instead of exiting so sabotage checks can catch a bad workflow.
gate_fail() {
  echo "ASSERT FAIL: $*" >&2
  return 1
}

assert_workflow() {
  local wf="$1"
  [[ -f "${wf}" ]] || { gate_fail "missing workflow ${wf}"; return 1; }

  local report scan prove test_step prove_only codecov
  report="$(extract_steps "${wf}" "jacoco:report")"
  [[ -n "${report}" ]] || { gate_fail "Build workflow must run mvn jacoco:report"; return 1; }
  if printf '%s\n' "${report}" | grep -q 'continue-on-error'; then
    gate_fail "JaCoCo report step must not continue-on-error (a failed report would stay green)"
    return 1
  fi

  scan="$(extract_steps "${wf}" --check-report)"
  [[ -n "${scan}" ]] || { gate_fail "Build workflow must fail when jacoco.xml is missing or empty (--check-report)"; return 1; }
  if printf '%s\n' "${scan}" | grep -q 'continue-on-error'; then
    gate_fail "JaCoCo XML scan must not continue-on-error"
    return 1
  fi
  if ! printf '%s\n' "${scan}" | grep -q 'if: always()'; then
    gate_fail "JaCoCo XML scan must run even when an earlier step failed (if: always())"
    return 1
  fi
  if ! printf '%s\n' "${scan}" | grep -q 'target/site/jacoco/jacoco.xml'; then
    gate_fail "JaCoCo XML scan must check target/site/jacoco/jacoco.xml"
    return 1
  fi

  prove="$(extract_steps "${wf}" "jacoco-report-assert.sh")"
  [[ -n "${prove}" ]] || { gate_fail "Build workflow must run jacoco-report-assert.sh"; return 1; }
  if ! prove_only="$(printf '%s\n' "${prove}" | awk '
    BEGIN { RS="---STEP---" }
    /jacoco-report-assert\.sh/ && !/--check-report/ { print; found=1 }
    END { if (!found) exit 1 }
  ')"; then
    gate_fail "Build workflow must run the JaCoCo report assert (wiring proof)"
    return 1
  fi
  if printf '%s\n' "${prove_only}" | grep -q 'continue-on-error'; then
    gate_fail "JaCoCo report assert step must not continue-on-error"
    return 1
  fi

  test_step="$(extract_steps "${wf}" "mvn -U -B test")"
  [[ -n "${test_step}" ]] || { gate_fail "Build workflow must run mvn -U -B test"; return 1; }
  if printf '%s\n' "${test_step}" | grep -q 'continue-on-error'; then
    gate_fail "mvn test step must not continue-on-error"
    return 1
  fi
  if printf '%s\n' "${test_step}" | grep -E -q 'skipTests|maven.test.skip|testFailureIgnore'; then
    gate_fail "mvn test step must not skip tests or ignore failures"
    return 1
  fi

  codecov="$(extract_steps "${wf}" "codecov/codecov-action")"
  [[ -n "${codecov}" ]] || { gate_fail "Build workflow must upload coverage with codecov/codecov-action"; return 1; }
  if ! printf '%s\n' "${codecov}" | grep -q 'continue-on-error: true'; then
    gate_fail "Codecov upload must stay non-blocking (continue-on-error: true)"
    return 1
  fi
}

if [[ "${1:-}" == "--check-report" ]]; then
  [[ $# -eq 2 ]] || fail "--check-report requires a file path"
  check_report "$2"
  exit 0
fi

[[ $# -eq 0 ]] || fail "unknown arguments: $*"

echo "== proving: workflow-gate =="
assert_workflow "${WORKFLOW}"
echo "workflow-gate OK"

echo "== proving: missing-jacoco-xml-reddens =="
expect_fail "missing jacoco xml" check_report "/tmp/jacoco-report-assert-missing-$$.xml"
if ! grep -q 'missing jacoco report' /tmp/jacoco-report-assert-err.txt; then
  fail "missing jacoco xml must say the report is missing"
fi
echo "missing-jacoco-xml-reddens OK"

echo "== proving: empty-jacoco-xml-reddens =="
empty="$(mktemp)"
: > "${empty}"
expect_fail "empty jacoco xml" check_report "${empty}"
if ! grep -q 'empty jacoco report' /tmp/jacoco-report-assert-err.txt; then
  fail "empty jacoco xml must say the report is empty"
fi
rm -f "${empty}"
echo "empty-jacoco-xml-reddens OK"

echo "== proving: whitespace-jacoco-xml-reddens =="
blank="$(mktemp)"
printf ' \n\t\n' > "${blank}"
expect_fail "whitespace jacoco xml" check_report "${blank}"
if ! grep -q 'empty jacoco report' /tmp/jacoco-report-assert-err.txt; then
  fail "whitespace jacoco xml must say the report is empty"
fi
rm -f "${blank}"
echo "whitespace-jacoco-xml-reddens OK"

echo "== proving: non-empty-jacoco-xml-passes =="
present="$(mktemp)"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<report name="orch-guide"></report>' > "${present}"
expect_ok "non-empty jacoco xml" check_report "${present}"
rm -f "${present}"
echo "non-empty-jacoco-xml-passes OK"

echo "== proving: sabotage-report-continue-on-error =="
sabotaged="$(mktemp)"
awk '
  /mvn -U -B jacoco:report/ && !done {
    print
    print "        continue-on-error: true"
    done = 1
    next
  }
  { print }
' "${WORKFLOW}" > "${sabotaged}"
expect_fail "sabotaged report continue-on-error" assert_workflow "${sabotaged}"
rm -f "${sabotaged}"
echo "sabotage-report-continue-on-error OK"

echo "== proving: sabotage-scan-removed =="
sabotaged="$(mktemp)"
grep -v -- '--check-report' "${WORKFLOW}" > "${sabotaged}"
expect_fail "sabotaged scan removed" assert_workflow "${sabotaged}"
rm -f "${sabotaged}"
echo "sabotage-scan-removed OK"

echo "== proving: sabotage-scan-continue-on-error =="
sabotaged="$(mktemp)"
awk '
  /Fail closed on missing JaCoCo report/ && !done {
    print
    print "        continue-on-error: true"
    done = 1
    next
  }
  { print }
' "${WORKFLOW}" > "${sabotaged}"
expect_fail "sabotaged scan continue-on-error" assert_workflow "${sabotaged}"
rm -f "${sabotaged}"
echo "sabotage-scan-continue-on-error OK"

echo "== proving: sabotage-codecov-blocking =="
sabotaged="$(mktemp)"
awk '
  /codecov\/codecov-action/ { in_codecov = 1 }
  in_codecov && /^        continue-on-error: true$/ { in_codecov = 0; next }
  /^      - / { in_codecov = 0 }
  { print }
' "${WORKFLOW}" > "${sabotaged}"
expect_fail "sabotaged codecov blocking" assert_workflow "${sabotaged}"
if ! grep -q 'Codecov upload must stay non-blocking' /tmp/jacoco-report-assert-err.txt; then
  fail "removing Codecov continue-on-error must say the upload must stay non-blocking"
fi
rm -f "${sabotaged}"
echo "sabotage-codecov-blocking OK"

echo "== proving: sabotage-skip-tests =="
sabotaged="$(mktemp)"
sed 's/mvn -U -B test$/mvn -U -B test -DskipTests/' "${WORKFLOW}" > "${sabotaged}"
expect_fail "sabotaged skipTests" assert_workflow "${sabotaged}"
rm -f "${sabotaged}"
echo "sabotage-skip-tests OK"

echo "jacoco-report-assert OK"
