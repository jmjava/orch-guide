#!/usr/bin/env bash
# Proves diff-scoped detekt fails on a changed Kotlin or Java line and allows
# an old finding on an unchanged line. Wiring sabotage (dropping the job) fails
# this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/detekt-cayc.sh"
WORKFLOW="${ROOT}/.github/workflows/detekt-cayc.yml"
JAVA_CONFIG="${ROOT}/scripts/detekt-cayc-java.xml"
chmod +x "${SCRIPT}"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >/tmp/detekt-cayc-assert-out.txt 2>/tmp/detekt-cayc-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/detekt-cayc-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/detekt-cayc-assert-err.txt >&2
    fail "${label}: expected non-zero exit"
  fi
}

expect_ok() {
  local label="$1"
  shift
  if ! "$@" >/tmp/detekt-cayc-assert-out.txt 2>/tmp/detekt-cayc-assert-err.txt; then
    echo "stdout:" >&2
    cat /tmp/detekt-cayc-assert-out.txt >&2
    echo "stderr:" >&2
    cat /tmp/detekt-cayc-assert-err.txt >&2
    fail "${label}: expected zero exit"
  fi
}

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"
[[ -f "${WORKFLOW}" ]] || fail "missing ${WORKFLOW}"
[[ -f "${JAVA_CONFIG}" ]] || fail "missing ${JAVA_CONFIG}"

echo "== proving: job-exists =="
if ! grep -qE '^[[:space:]]*detekt-cayc:[[:space:]]*$' "${WORKFLOW}"; then
  fail "workflow must define job detekt-cayc"
fi
if ! grep -q 'detekt-cayc.sh' "${WORKFLOW}"; then
  fail "workflow must invoke detekt-cayc.sh"
fi
if ! grep -q 'detekt-cayc-assert.sh' "${WORKFLOW}"; then
  fail "workflow must invoke this assert so wiring sabotage stays red"
fi
if grep -q 'continue-on-error' "${WORKFLOW}"; then
  fail "detekt-cayc must not continue-on-error"
fi
if ! grep -q '\.java' "${SCRIPT}"; then
  fail "gate must include Java sources"
fi
if grep -q 'SuppressionFilter' "${JAVA_CONFIG}"; then
  fail "java ruleset must not suppress findings"
fi
if grep -q 'fail_ci_if_error: true' "${ROOT}/.github/workflows/maven.yml"; then
  fail "codecov upload must stay non-blocking"
fi
echo "job-exists OK"

echo "== proving: refuses-baseline-rewrite =="
expect_fail "refuses-baseline-rewrite" "${SCRIPT}" --create-baseline
if ! grep -q 'refusing to rewrite the detekt baseline' /tmp/detekt-cayc-assert-err.txt; then
  fail "baseline rewrite must be refused"
fi
if grep -q -- '--baseline' "${SCRIPT}"; then
  fail "clean-as-you-code must not pass a detekt baseline"
fi
echo "refuses-baseline-rewrite OK"

init_repo() {
  local dir="$1"
  git init -q -b main "$dir"
  git -C "$dir" -c user.email="detekt-cayc@example.com" -c user.name="detekt-cayc" commit -q --allow-empty -m "init"
}

commit_tree() {
  local dir="$1"
  git -C "$dir" add -A
  git -C "$dir" -c user.email="detekt-cayc@example.com" -c user.name="detekt-cayc" commit -q -m "fixture"
}

echo "== proving: changed-line-fails =="
changed="$(mktemp -d)"
init_repo "$changed"
mkdir -p "${changed}/src/main/kotlin/demo"
cat > "${changed}/src/main/kotlin/demo/Sample.kt" <<'EOF'
package demo

fun stable() {
    println("stable")
}

fun edited() {
    println("edited")
}
EOF
commit_tree "$changed"
cat > "${changed}/src/main/kotlin/demo/Sample.kt" <<'EOF'
package demo

fun stable() {
    println("stable")
}

fun edited(): Int {
    return 42
}
EOF
expect_fail "changed-line-fails" env DETEKT_CAYC_ROOT="$changed" DETEKT_BASE=HEAD "${SCRIPT}"
if ! grep -q 'FunctionOnlyReturningConstant' /tmp/detekt-cayc-assert-err.txt; then
  fail "changed-line-fails must report FunctionOnlyReturningConstant"
fi
echo "changed-line-fails OK"

echo "== proving: unchanged-line-stays-visible =="
quiet="$(mktemp -d)"
init_repo "$quiet"
mkdir -p "${quiet}/src/main/kotlin/demo"
cat > "${quiet}/src/main/kotlin/demo/Sample.kt" <<'EOF'
package demo

fun stable() {
    println("stable")
}

fun edited(): Int {
    return 42
}
EOF
commit_tree "$quiet"
cat > "${quiet}/src/main/kotlin/demo/Sample.kt" <<'EOF'
package demo

fun stable() {
    println("still-stable")
}

fun edited(): Int {
    return 42
}
EOF
expect_ok "unchanged-line-stays-visible" env DETEKT_CAYC_ROOT="$quiet" DETEKT_BASE=HEAD "${SCRIPT}"
if ! grep -q 'FunctionOnlyReturningConstant' /tmp/detekt-cayc-assert-out.txt; then
  fail "old finding must stay visible"
fi
if ! grep -q 'not a failure' /tmp/detekt-cayc-assert-out.txt; then
  fail "old finding must be marked as not a failure"
fi
echo "unchanged-line-stays-visible OK"

echo "== proving: java-changed-line-fails =="
java_changed="$(mktemp -d)"
init_repo "$java_changed"
mkdir -p "${java_changed}/src/main/java/demo"
cat > "${java_changed}/src/main/java/demo/Sample.java" <<'EOF'
package demo;

public class Sample {
    public void stable() {
        System.out.println("stable");
    }

    public void edited() {
        System.out.println("edited");
    }
}
EOF
commit_tree "$java_changed"
cat > "${java_changed}/src/main/java/demo/Sample.java" <<'EOF'
package demo;

public class Sample {
    public void stable() {
        System.out.println("stable");
    }

    public void edited() {
        try {
            System.out.println("edited");
        } catch (RuntimeException ex) {
        }
    }
}
EOF
expect_fail "java-changed-line-fails" env DETEKT_CAYC_ROOT="$java_changed" DETEKT_BASE=HEAD "${SCRIPT}"
if ! grep -q 'EmptyCatchBlock' /tmp/detekt-cayc-assert-err.txt; then
  fail "java-changed-line-fails must report EmptyCatchBlock"
fi
echo "java-changed-line-fails OK"

echo "== proving: java-unchanged-line-stays-visible =="
java_quiet="$(mktemp -d)"
init_repo "$java_quiet"
mkdir -p "${java_quiet}/src/main/java/demo"
cat > "${java_quiet}/src/main/java/demo/Sample.java" <<'EOF'
package demo;

public class Sample {
    public void stable() {
        System.out.println("stable");
    }

    public void edited() {
        try {
            System.out.println("edited");
        } catch (RuntimeException ex) {
        }
    }
}
EOF
commit_tree "$java_quiet"
cat > "${java_quiet}/src/main/java/demo/Sample.java" <<'EOF'
package demo;

public class Sample {
    public void stable() {
        System.out.println("still-stable");
    }

    public void edited() {
        try {
            System.out.println("edited");
        } catch (RuntimeException ex) {
        }
    }
}
EOF
expect_ok "java-unchanged-line-stays-visible" env DETEKT_CAYC_ROOT="$java_quiet" DETEKT_BASE=HEAD "${SCRIPT}"
if ! grep -q 'EmptyCatchBlock' /tmp/detekt-cayc-assert-out.txt; then
  fail "old Java finding must stay visible"
fi
if ! grep -q 'not a failure' /tmp/detekt-cayc-assert-out.txt; then
  fail "old Java finding must be marked as not a failure"
fi
echo "java-unchanged-line-stays-visible OK"

echo "== proving: no-kotlin-or-java-passes =="
plain="$(mktemp -d)"
init_repo "$plain"
echo "notes" > "${plain}/README.md"
commit_tree "$plain"
echo "notes changed" > "${plain}/README.md"
expect_ok "no-kotlin-or-java-passes" env DETEKT_CAYC_ROOT="$plain" DETEKT_BASE=HEAD "${SCRIPT}"
if ! grep -q 'no Kotlin or Java changes' /tmp/detekt-cayc-assert-out.txt; then
  fail "a non-source diff must say no Kotlin or Java changes"
fi
echo "no-kotlin-or-java-passes OK"

echo "== proving: missing-base-fails =="
expect_fail "missing-base-fails" env DETEKT_CAYC_ROOT="$plain" DETEKT_BASE=refs/does-not-exist "${SCRIPT}"
if ! grep -q 'base ref refs/does-not-exist is missing' /tmp/detekt-cayc-assert-err.txt; then
  fail "missing base must be fail-closed"
fi
echo "missing-base-fails OK"

rm -rf "$changed" "$quiet" "$java_changed" "$java_quiet" "$plain"
echo "detekt-cayc-assert OK"
