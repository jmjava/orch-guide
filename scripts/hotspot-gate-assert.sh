#!/usr/bin/env bash
# Proves a changed Java or Kotlin file fails only when it is both complex
# and in the top change-frequency set. A one-line edit in a quiet file
# passes. An unchanged complex hotspot stays visible and does not fail.
# Wiring sabotage (dropping the job) fails this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/hotspot-gate.sh"
GATE="${ROOT}/scripts/hotspot_gate.py"
WORKFLOW="${ROOT}/.github/workflows/hotspot-gate.yml"
chmod +x "${SCRIPT}"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/tmp/hotspot-gate-assert-out.txt 2>/tmp/hotspot-gate-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/hotspot-gate-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/hotspot-gate-assert-err.txt >&2
    fail "${label}: expected non-zero exit"
  fi
}

expect_ok() {
  local label="$1"
  shift
  if ! "$@" >/tmp/hotspot-gate-assert-out.txt 2>/tmp/hotspot-gate-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/hotspot-gate-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/hotspot-gate-assert-err.txt >&2
    fail "${label}: expected zero exit"
  fi
}

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"
[[ -f "${GATE}" ]] || fail "missing ${GATE}"
[[ -f "${WORKFLOW}" ]] || fail "missing ${WORKFLOW}"

echo "== proving: job-exists =="
if ! grep -qE '^[[:space:]]*hotspot-gate:[[:space:]]*$' "${WORKFLOW}"; then
  fail "workflow must define job hotspot-gate"
fi
if ! grep -q 'hotspot-gate.sh' "${WORKFLOW}"; then
  fail "workflow must invoke hotspot-gate.sh"
fi
if ! grep -q 'hotspot-gate-assert.sh' "${WORKFLOW}"; then
  fail "workflow must invoke this assert so wiring sabotage stays red"
fi
if grep -q 'continue-on-error' "${WORKFLOW}"; then
  fail "hotspot-gate must not continue-on-error"
fi
if grep -qE -- '--complex-ccn|--top-fraction|--create-baseline|--write-baseline' "${WORKFLOW}"; then
  fail "workflow must not raise the ceiling or rewrite a baseline"
fi
echo "job-exists OK"

echo "== proving: refuses-ceiling-or-baseline =="
expect_fail "refuses-baseline" "${SCRIPT}" --create-baseline
if ! grep -q 'refusing to raise the complexity ceiling or rewrite a baseline' /tmp/hotspot-gate-assert-err.txt; then
  fail "baseline rewrite must be refused"
fi
expect_fail "refuses-ceiling" "${SCRIPT}" --complex-ccn
expect_fail "refuses-python-ceiling" python3 "${GATE}" --repo "${ROOT}" --base HEAD --complex-ccn 50
if ! grep -q 'refusing to change the complexity ceiling' /tmp/hotspot-gate-assert-err.txt; then
  fail "a higher complexity ceiling must be refused"
fi
if ! grep -q 'DEFAULT_COMPLEX_CCN = 10' "${GATE}"; then
  fail "complexity ceiling must stay at 10"
fi
echo "refuses-ceiling-or-baseline OK"

commit_tree() {
  local dir="$1"
  local message="$2"
  git -C "$dir" add -A
  git -C "$dir" -c user.email="hotspot-gate@example.com" -c user.name="hotspot-gate" commit -q -m "$message"
}

init_repo() {
  local dir="$1"
  git init -q -b main "$dir"
  git -C "$dir" -c user.email="hotspot-gate@example.com" -c user.name="hotspot-gate" commit -q --allow-empty -m "init"
}

scenario() {
  local ext="$1"
  local tmp
  tmp="$(mktemp -d)"
  init_repo "$tmp"
  if [[ "$ext" == "java" ]]; then
    cat > "$tmp/quiet.java" <<'EOF'
class Quiet {
    int complex(int x) {
        if (x == 1) return 1;
        if (x == 2) return 2;
        if (x == 3) return 3;
        if (x == 4) return 4;
        if (x == 5) return 5;
        if (x == 6) return 6;
        if (x == 7) return 7;
        if (x == 8) return 8;
        if (x == 9) return 9;
        return 0;
    }
}
EOF
    cp "$tmp/quiet.java" "$tmp/hot.java"
    printf 'class Simple { int simple(int x) { return x; } }\n' > "$tmp/simple.java"
  else
    cat > "$tmp/quiet.kt" <<'EOF'
fun complex(x: Int): Int {
    if (x == 1) return 1
    if (x == 2) return 2
    if (x == 3) return 3
    if (x == 4) return 4
    if (x == 5) return 5
    if (x == 6) return 6
    if (x == 7) return 7
    if (x == 8) return 8
    if (x == 9) return 9
    return 0
}
EOF
    cp "$tmp/quiet.kt" "$tmp/hot.kt"
    printf 'fun simple(x: Int) = x\n' > "$tmp/simple.kt"
  fi
  commit_tree "$tmp" "base"
  local n
  for n in 1 2 3 4 5 6 7; do
    printf '\n' >> "$tmp/hot.$ext"
    printf '\n' >> "$tmp/simple.$ext"
    commit_tree "$tmp" "churn $n"
  done
  expect_ok "clean-$ext" python3 "${GATE}" --repo "$tmp" --base HEAD
  if ! grep -q "existing hotspot (does not fail): hot.${ext}" /tmp/hotspot-gate-assert-out.txt; then
    fail "unchanged complex hotspot ${ext} must stay visible"
  fi
  if grep -q 'hotspot-gate: FAIL' /tmp/hotspot-gate-assert-err.txt; then
    fail "unchanged complex hotspot ${ext} must not fail the build"
  fi
  printf '// one line\n' >> "$tmp/quiet.$ext"
  expect_ok "quiet-complex-$ext" python3 "${GATE}" --repo "$tmp" --base HEAD
  if ! grep -q "pass quiet.$ext" /tmp/hotspot-gate-assert-out.txt; then
    fail "quiet complex $ext file must be reported as a pass"
  fi
  if ! grep -q "existing hotspot (does not fail): hot.${ext}" /tmp/hotspot-gate-assert-out.txt; then
    fail "old hotspot ${ext} must stay visible when a quiet file changes"
  fi
  git -C "$tmp" checkout -q -- "quiet.$ext"
  printf '// one line\n' >> "$tmp/simple.$ext"
  expect_ok "hot-simple-$ext" python3 "${GATE}" --repo "$tmp" --base HEAD
  git -C "$tmp" checkout -q -- "simple.$ext"
  printf '// one line\n' >> "$tmp/hot.$ext"
  expect_fail "hot-complex-$ext" python3 "${GATE}" --repo "$tmp" --base HEAD
  if ! grep -q "hot.$ext" /tmp/hotspot-gate-assert-err.txt; then
    fail "complex hotspot $ext must be named in the failure"
  fi
  if ! grep -q 'complex hotspot' /tmp/hotspot-gate-assert-err.txt; then
    fail "complex hotspot $ext must say complex hotspot"
  fi
  rm -rf "$tmp"
}

echo "== proving: java =="
scenario java
echo "java OK"

echo "== proving: kotlin =="
scenario kt
echo "kotlin OK"

echo "== proving: non-source-passes =="
plain="$(mktemp -d)"
init_repo "$plain"
echo "notes" > "${plain}/README.md"
commit_tree "$plain" "notes"
echo "notes changed" > "${plain}/README.md"
expect_ok "non-source-passes" python3 "${GATE}" --repo "$plain" --base HEAD
if ! grep -q 'no Java or Kotlin changes' /tmp/hotspot-gate-assert-out.txt; then
  fail "a non-source diff must say no Java or Kotlin changes"
fi
echo "non-source-passes OK"

echo "== proving: missing-base-fails =="
expect_fail "missing-base-fails" python3 "${GATE}" --repo "$plain" --base refs/does-not-exist
if ! grep -q 'base ref refs/does-not-exist is missing' /tmp/hotspot-gate-assert-err.txt; then
  fail "missing base must be fail-closed"
fi
echo "missing-base-fails OK"

rm -rf "$plain"
echo "hotspot-gate-assert OK"
