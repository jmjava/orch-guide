#!/usr/bin/env bash
# Fail if refs/tags/<PIN_TAG> is missing or peels to a commit other than PIN_SHA.
# Resolve the tag as refs/tags/... — a local branch of the same name must not count.
# This script never creates, moves, or pushes the pin tag.
# Leftover #8: tag bump is a deliberate leftover. Do not retag from a
# silent README edit. Pin stays 187d4d4 (LEFTOVER_8_PIN_SHA).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: assert-spdd-projection-pin.sh [--self-test]

  (default)  Fetch refs/tags/<PIN_TAG> from origin when present and fail if
             the tag is missing or peels to a commit other than PIN_SHA.
             Leftover #8 also fails if pin.env is no longer 187d4d4.
  --self-test
             Proving cases in a throwaway repo: missing-tag-fails,
             wrong-sha-fails, matching-sha-passes,
             silent-readme-edit-does-not-retag, pin-stays-187d4d4,
             assert-pin-never-retags.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PIN_FILE="${SCRIPT_DIR}/spdd-projection-pin.env"

# Leftover #8: pin stays 187d4d4 until a leftover deliberately updates both
# this constant and scripts/spdd-projection-pin.env. Do not retag from a
# README-only edit.
LEFTOVER_8_PIN_TAG=spdd-projection-v3
LEFTOVER_8_PIN_SHA=187d4d4a27a8284bc4c6ee0709b226ac70aa0129

load_pin() {
  local pin_file="$1"
  if [[ ! -f "${pin_file}" ]]; then
    echo "assert-spdd-projection-pin: missing pin file ${pin_file}" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "${pin_file}"
  if [[ -z "${PIN_TAG:-}" || -z "${PIN_SHA:-}" ]]; then
    echo "assert-spdd-projection-pin: ${pin_file} must set PIN_TAG and PIN_SHA" >&2
    return 1
  fi
  if [[ ! "${PIN_SHA}" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "assert-spdd-projection-pin: PIN_SHA must be a lowercase hex SHA, got '${PIN_SHA}'" >&2
    return 1
  fi
}

sha_matches() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" ]] && return 0
  [[ "${actual}" == "${expected}"* ]] && return 0
  [[ "${expected}" == "${actual}"* ]] && return 0
  return 1
}

assert_pin() {
  local git_root="$1"
  local pin_file="$2"
  local fetch_remote="${3:-}"

  # A caller (or Cursor/agent) GIT_DIR must not shadow the work tree under test.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

  load_pin "${pin_file}"

  if [[ ! -d "${git_root}/.git" && ! -f "${git_root}/.git" ]]; then
    echo "assert-spdd-projection-pin: ${git_root} is not a git work tree" >&2
    return 1
  fi

  if [[ -n "${fetch_remote}" ]]; then
    if git -C "${git_root}" remote get-url "${fetch_remote}" >/dev/null 2>&1; then
      if ! git -C "${git_root}" fetch "${fetch_remote}" \
        "refs/tags/${PIN_TAG}:refs/tags/${PIN_TAG}" --no-tags --force; then
        if ! git -C "${git_root}" show-ref --verify --quiet "refs/tags/${PIN_TAG}"; then
          echo "assert-spdd-projection-pin: could not fetch refs/tags/${PIN_TAG} from ${fetch_remote} and the tag is missing locally" >&2
          return 1
        fi
        echo "assert-spdd-projection-pin: warning: could not refresh refs/tags/${PIN_TAG} from ${fetch_remote}; asserting local tag" >&2
      fi
    fi
  fi

  if ! git -C "${git_root}" show-ref --verify --quiet "refs/tags/${PIN_TAG}"; then
    echo "assert-spdd-projection-pin: missing tag refs/tags/${PIN_TAG}" >&2
    return 1
  fi

  local actual
  if ! actual="$(git -C "${git_root}" rev-parse --verify "refs/tags/${PIN_TAG}^{commit}" 2>/dev/null)"; then
    echo "assert-spdd-projection-pin: refs/tags/${PIN_TAG} exists but does not peel to a commit" >&2
    return 1
  fi

  if ! sha_matches "${actual}" "${PIN_SHA}"; then
    echo "assert-spdd-projection-pin: refs/tags/${PIN_TAG} peels to ${actual}, expected ${PIN_SHA}" >&2
    return 1
  fi

  local readme="${git_root}/README.md"
  if [[ -f "${readme}" ]]; then
    local short="${PIN_SHA:0:7}"
    if ! grep -q -F "${PIN_TAG}" "${readme}"; then
      echo "assert-spdd-projection-pin: README.md does not mention pin tag ${PIN_TAG}" >&2
      return 1
    fi
    if ! grep -q -F "${short}" "${readme}"; then
      echo "assert-spdd-projection-pin: README.md does not mention pin SHA ${short}" >&2
      return 1
    fi
  fi

  echo "assert-spdd-projection-pin: ok refs/tags/${PIN_TAG} -> ${actual}"
}

# Leftover #8: pin.env must stay on 187d4d4. A silent README leftover must
# not bump PIN_SHA / PIN_TAG. Uses DEFAULT_PIN_FILE only (not throwaway pins).
assert_leftover_8_pin_stays() {
  local saved_tag="${PIN_TAG:-}"
  local saved_sha="${PIN_SHA:-}"
  local pin_file="${DEFAULT_PIN_FILE}"

  if [[ ! -f "${pin_file}" ]]; then
    echo "assert-spdd-projection-pin: leftover #8: missing pin file ${pin_file}" >&2
    return 1
  fi
  if ! grep -q 'Leftover #8' "${pin_file}"; then
    echo "assert-spdd-projection-pin: leftover #8: ${pin_file} must name leftover #8" >&2
    return 1
  fi
  if ! grep -q 'deliberate leftover' "${pin_file}"; then
    echo "assert-spdd-projection-pin: leftover #8: ${pin_file} must say tag bump is a deliberate leftover" >&2
    return 1
  fi
  if ! grep -q 'Do not retag' "${pin_file}"; then
    echo "assert-spdd-projection-pin: leftover #8: ${pin_file} must say Do not retag" >&2
    return 1
  fi
  if ! grep -q 'Pin stays 187d4d4' "${pin_file}"; then
    echo "assert-spdd-projection-pin: leftover #8: ${pin_file} must say Pin stays 187d4d4" >&2
    return 1
  fi

  load_pin "${pin_file}"
  if [[ "${PIN_TAG}" != "${LEFTOVER_8_PIN_TAG}" ]]; then
    echo "assert-spdd-projection-pin: leftover #8: PIN_TAG must stay ${LEFTOVER_8_PIN_TAG}, got ${PIN_TAG}" >&2
    PIN_TAG="${saved_tag}"
    PIN_SHA="${saved_sha}"
    return 1
  fi
  if [[ "${PIN_SHA}" != "${LEFTOVER_8_PIN_SHA}" ]]; then
    echo "assert-spdd-projection-pin: leftover #8: pin stays 187d4d4, got ${PIN_SHA}" >&2
    PIN_TAG="${saved_tag}"
    PIN_SHA="${saved_sha}"
    return 1
  fi
  PIN_TAG="${saved_tag}"
  PIN_SHA="${saved_sha}"
  echo "assert-spdd-projection-pin: leftover #8 pin-stays-187d4d4 ok"
}

# Leftover #8: assert_pin must never create or move the pin tag.
assert_pin_never_retags() {
  local script="${SCRIPT_DIR}/assert-spdd-projection-pin.sh"
  if awk '/^assert_pin\(\)/,/^}/' "${script}" | grep -qE 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?tag[[:space:]]'; then
    echo "PROVE FAIL: assert_pin must not create or move tags" >&2
    return 1
  fi
  echo "PROVE OK: assert-pin-never-retags"
}

expect_fail() {
  local name="$1"
  shift
  if "$@"; then
    echo "PROVE FAIL: ${name} expected a red assertion" >&2
    return 1
  fi
  echo "PROVE OK: ${name}"
}

expect_pass() {
  local name="$1"
  shift
  if ! "$@"; then
    echo "PROVE FAIL: ${name} expected a green assertion" >&2
    return 1
  fi
  echo "PROVE OK: ${name}"
}

write_pin_file() {
  local path="$1"
  local tag="$2"
  local sha="$3"
  mkdir -p "$(dirname "${path}")"
  cat >"${path}" <<EOF
PIN_TAG=${tag}
PIN_SHA=${sha}
EOF
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' RETURN

  git init -q "${tmp}"
  git -C "${tmp}" config user.email "pin-test@invalid"
  git -C "${tmp}" config user.name "pin-test"
  git -C "${tmp}" checkout -q -b main

  printf 'pin %s (%s)\n' "spdd-projection-v3" "placeholder" >"${tmp}/README.md"
  git -C "${tmp}" add README.md
  git -C "${tmp}" commit -q -m "base"
  local sha_a
  sha_a="$(git -C "${tmp}" rev-parse HEAD)"

  printf 'second commit\n' >>"${tmp}/README.md"
  git -C "${tmp}" add README.md
  git -C "${tmp}" commit -q -m "other"
  local sha_b
  sha_b="$(git -C "${tmp}" rev-parse HEAD)"

  local pin="${tmp}/scripts/spdd-projection-pin.env"
  write_pin_file "${pin}" "spdd-projection-v3" "${sha_a}"
  printf 'pin `spdd-projection-v3` (`%s`)\n' "${sha_a:0:7}" >"${tmp}/README.md"

  echo "== proving: missing-tag-fails =="
  expect_fail "missing-tag-fails" assert_pin "${tmp}" "${pin}" ""

  echo "== proving: branch-name-collision-is-not-the-tag =="
  git -C "${tmp}" branch "spdd-projection-v3" "${sha_a}"
  expect_fail "branch-name-collision-is-not-the-tag" assert_pin "${tmp}" "${pin}" ""

  echo "== proving: wrong-sha-fails =="
  git -C "${tmp}" tag -a "spdd-projection-v3" "${sha_b}" -m "wrong pin"
  expect_fail "wrong-sha-fails" assert_pin "${tmp}" "${pin}" ""

  echo "== proving: matching-sha-passes =="
  git -C "${tmp}" tag -d "spdd-projection-v3" >/dev/null
  git -C "${tmp}" tag -a "spdd-projection-v3" "${sha_a}" -m "correct pin"
  expect_pass "matching-sha-passes" assert_pin "${tmp}" "${pin}" ""

  # Leftover #8: a silent README-only edit must not retag. Pin stays at sha_a.
  echo "== proving: silent-readme-edit-does-not-retag =="
  local tag_before tag_after sha_readme
  tag_before="$(git -C "${tmp}" rev-parse --verify "refs/tags/spdd-projection-v3^{commit}")"
  printf 'pin `spdd-projection-v3` (`%s`)\n\nSilent leftover README edit.\n' "${sha_a:0:7}" \
    >"${tmp}/README.md"
  git -C "${tmp}" add README.md
  git -C "${tmp}" commit -q -m "docs: silent leftover readme"
  sha_readme="$(git -C "${tmp}" rev-parse HEAD)"
  expect_pass "silent-readme-edit-does-not-retag" assert_pin "${tmp}" "${pin}" ""
  tag_after="$(git -C "${tmp}" rev-parse --verify "refs/tags/spdd-projection-v3^{commit}")"
  if [[ "${tag_before}" != "${tag_after}" ]]; then
    echo "PROVE FAIL: silent README edit retagged spdd-projection-v3" >&2
    return 1
  fi
  if [[ "${tag_after}" == "${sha_readme}" ]]; then
    echo "PROVE FAIL: tag moved to the README-only commit" >&2
    return 1
  fi
  if [[ "${tag_after}" != "${sha_a}" ]]; then
    echo "PROVE FAIL: tag no longer at original pin ${sha_a}" >&2
    return 1
  fi
  echo "PROVE OK: silent-readme-edit-does-not-retag (tag stayed ${sha_a:0:7})"

  echo "== proving: assert-pin-never-retags =="
  assert_pin_never_retags

  echo "== proving: pin-stays-187d4d4 =="
  expect_pass "pin-stays-187d4d4" assert_leftover_8_pin_stays

  echo "assert-spdd-projection-pin: self-test ok"
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      ;;
    --self-test)
      self_test
      ;;
    "")
      local root
      root="$(cd "${SCRIPT_DIR}/.." && pwd)"
      assert_leftover_8_pin_stays
      assert_pin "${root}" "${DEFAULT_PIN_FILE}" "origin"
      ;;
    *)
      echo "assert-spdd-projection-pin: unknown argument: $1" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
