#!/usr/bin/env bash
# Proves the maintainability ratchets can go red.
# Does not run PIT. Mutation stays in the GitHub workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DETEKT="${ROOT}/scripts/detekt-ratchet.sh"
HOTSPOT="${ROOT}/scripts/hotspot-gate.py"
FORBID="${ROOT}/scripts/forbid-embabel-upstream.sh"
WORKFLOW="${ROOT}/.github/workflows/maintainability-ratchets.yml"
BASELINE="${ROOT}/config/detekt/baseline.xml"
chmod +x "$DETEKT" "$FORBID" "$HOTSPOT"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/tmp/ratchet-assert-out.txt 2>/tmp/ratchet-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/ratchet-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/ratchet-assert-err.txt >&2
    fail "${label}: expected non-zero exit"
  fi
}

expect_ok() {
  local label="$1"
  shift
  if ! "$@" >/tmp/ratchet-assert-out.txt 2>/tmp/ratchet-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/ratchet-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/ratchet-assert-err.txt >&2
    fail "${label}: expected zero exit"
  fi
}

[[ -f "$BASELINE" ]] || fail "missing frozen baseline ${BASELINE}"
[[ -f "$WORKFLOW" ]] || fail "missing ${WORKFLOW}"
[[ -f "$FORBID" ]] || fail "fitness boundary must stay scripts/forbid-embabel-upstream.sh"

echo "== proving: CI does not rewrite the baseline =="
if grep -q 'create-baseline' "$WORKFLOW"; then
  fail "workflow must not pass --create-baseline"
fi
if ! grep -q 'git diff --exit-code -- config/detekt/baseline.xml' "$WORKFLOW"; then
  fail "workflow must fail if the frozen baseline changes"
fi
if ! grep -q 'pitest:mutationCoverage' "$WORKFLOW"; then
  fail "workflow must contain the PIT command for GitHub"
fi
if grep -q 'pitest:mutationCoverage' "$DETEKT" "$HOTSPOT"; then
  fail "PIT stays in the mutation job"
fi
before="$(sha256sum "$BASELINE")"
expect_fail "create-baseline refused" "$DETEKT" --create-baseline
if ! grep -q 'refusing to rewrite the detekt baseline' /tmp/ratchet-assert-err.txt; then
  fail "create-baseline refusal must say the baseline is not rewritten"
fi
after="$(sha256sum "$BASELINE")"
[[ "$before" == "$after" ]] || fail "refused create-baseline still changed the baseline"
echo "CI does not rewrite the baseline OK"

echo "== proving: fitness boundary delegates to forbid-embabel-upstream.sh =="
if grep -q 'FORBIDDEN_RE=' "$DETEKT" "$HOTSPOT"; then
  fail "do not duplicate scripts/forbid-embabel-upstream.sh"
fi
if [[ -e "${ROOT}/scripts/fitness-embabel-upstream.sh" ]]; then
  fail "do not add a second copy of the forbid script"
fi
if ! grep -q 'forbid-embabel-upstream.sh' "$WORKFLOW"; then
  fail "workflow must invoke scripts/forbid-embabel-upstream.sh"
fi
expect_ok "live repo has no embabel/guide push or PR target" "$FORBID"
expect_fail "push URL fails" \
  "$FORBID" --pre-push evil https://github.com/embabel/guide.git
if ! grep -q 'embabel/guide' /tmp/ratchet-assert-err.txt; then
  fail "push URL failure must name embabel/guide"
fi
expect_fail "PR target fails" \
  env FORBID_GH_DEFAULT=embabel/guide "$FORBID"
if ! grep -q 'GitHub CLI default repo is embabel/guide' /tmp/ratchet-assert-err.txt; then
  fail "PR target failure must name the GitHub CLI default repo"
fi
echo "fitness boundary OK"

echo "== proving: hotspot gate =="
expect_ok "hotspot self-test" python3 "$HOTSPOT" --self-test
if ! grep -q 'complex-and-hot OK' /tmp/ratchet-assert-out.txt; then
  fail "hotspot self-test must show the complex-and-hot failure case"
fi
expect_ok "live hotspot gate" python3 "$HOTSPOT"
echo "hotspot gate OK"

echo "== proving: clean-as-you-code on changed lines =="
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git init -q "$fixture"
git -C "$fixture" config user.email ratchet@example.com
git -C "$fixture" config user.name ratchet
mkdir -p "$fixture/src/main/kotlin/sample" "$fixture/config/detekt"
long_old="    val message = \"$(printf 'x%.0s' {1..140})\""
long_new="    val extra = \"$(printf 'y%.0s' {1..140})\""
cat >"$fixture/src/main/kotlin/sample/Sample.kt" <<EOF
package sample

fun oldIssue() {
${long_old}
}

fun ok() = 1
EOF
git -C "$fixture" add src
git -C "$fixture" commit -q -m "base"
git -C "$fixture" update-ref refs/remotes/origin/main HEAD
expect_ok "fetch detekt cli" "$DETEKT" fetch
jar="${XDG_CACHE_HOME:-$HOME/.cache}/detekt/detekt-cli-2.0.0-alpha.3-all.jar"
[[ -f "$jar" ]] || fail "detekt cli jar is required to prove the line gate"
java -jar "$jar" \
  --input "$fixture/src/main/kotlin" \
  --baseline "$fixture/config/detekt/baseline.xml" \
  --base-path "$fixture" \
  --language-version 2.3 \
  --jvm-target 21 \
  --build-upon-default-config \
  --create-baseline \
  --fail-on-severity Never >/dev/null
fixture_base="$(sha256sum "$fixture/config/detekt/baseline.xml")"
if ! grep -q 'MaxLineLength:Sample.kt' "$fixture/config/detekt/baseline.xml"; then
  fail "fixture baseline must record the existing long line"
fi
cat >"$fixture/src/main/kotlin/sample/Sample.kt" <<EOF
package sample

fun oldIssue() {
${long_old}
}

fun ok() = 1

fun newIssue() {
${long_new}
}
EOF
git -C "$fixture" add src
git -C "$fixture" commit -q -m "new long line"
expect_fail "new finding on a changed line" \
  env RATCHET_ROOT="$fixture" RATCHET_BASELINE="$fixture/config/detekt/baseline.xml" \
  "$DETEKT" cayc
if ! grep -q 'frozen baseline findings' /tmp/ratchet-assert-out.txt; then
  fail "old findings must stay visible"
fi
if ! grep -q 'MaxLineLength:Sample.kt' /tmp/ratchet-assert-out.txt; then
  fail "the frozen MaxLineLength finding must be printed"
fi
if ! grep -q 'clean-as-you-code failed on changed lines' /tmp/ratchet-assert-err.txt; then
  fail "changed-line finding must fail clean-as-you-code"
fi
now_fixture="$(sha256sum "$fixture/config/detekt/baseline.xml")"
[[ "$fixture_base" == "$now_fixture" ]] || fail "cayc rewrote the fixture baseline"
git -C "$fixture" checkout -q origin/main -- src/main/kotlin/sample/Sample.kt
python3 - "$fixture/src/main/kotlin/sample/Sample.kt" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("fun ok() = 1", "fun ok() = 2"))
PY
git -C "$fixture" add src
git -C "$fixture" commit -q -m "touch unchanged issue"
expect_ok "old finding on an unchanged line does not fail" \
  env RATCHET_ROOT="$fixture" RATCHET_BASELINE="$fixture/config/detekt/baseline.xml" \
  "$DETEKT" cayc
if ! grep -q 'MaxLineLength:Sample.kt' /tmp/ratchet-assert-out.txt; then
  fail "old finding must still be printed when the gate passes"
fi
if ! grep -q 'no new findings on changed lines' /tmp/ratchet-assert-out.txt; then
  fail "clean-as-you-code must pass when the edit does not add a finding"
fi
echo "clean-as-you-code OK"

echo "== proving: frozen baseline fails a new finding and stays byte-stable =="
expect_ok "live baseline" "$DETEKT" baseline
expect_ok "live clean-as-you-code" "$DETEKT" cayc
live_before="$(sha256sum "$BASELINE")"
sabotage="$(mktemp)"
awk 'BEGIN{n=0} /<ID>/{if(n==0){n=1; next}} {print}' "$BASELINE" >"$sabotage"
if cmp -s "$BASELINE" "$sabotage"; then
  fail "sabotage did not remove a baseline id"
fi
expect_fail "dropped baseline id is a new finding" \
  env RATCHET_BASELINE="$sabotage" "$DETEKT" baseline
if ! grep -q 'new findings are not in the frozen baseline' /tmp/ratchet-assert-err.txt; then
  fail "baseline gate must report new findings"
fi
live_after="$(sha256sum "$BASELINE")"
[[ "$live_before" == "$live_after" ]] || fail "baseline gate rewrote the frozen baseline"
rm -f "$sabotage"
echo "frozen baseline OK"

echo "maintainability ratchets assert OK"
