#!/usr/bin/env bash
# Fail if this clone is configured to push to embabel/guide, or if the current
# push destination is embabel/guide. Used as a pre-push hook and CI check.
#
# Usage:
#   ./scripts/forbid-embabel-upstream.sh
#   ./scripts/forbid-embabel-upstream.sh --fix
#   ./scripts/forbid-embabel-upstream.sh --pre-push <remote-name> <remote-url>
#   ./scripts/forbid-embabel-upstream.sh --self-test
#
# --fix disables push on remotes named upstream/embabel whose fetch URL is
# embabel/guide (fetch stays; push URL becomes DISABLED). Never use
# `git remote set-url` without --push — that would drop fetch-from-Embabel.
# FORBID_GIT_ROOT overrides the repo the git remotes are read from (CI proving
# tests).
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${FORBID_GIT_ROOT:-$SCRIPT_ROOT}"

FORBIDDEN_RE='github\.com[:/]+embabel/guide(\.git)?(/*)?$'

usage() {
  cat <<'EOF'
Usage: forbid-embabel-upstream.sh [--fix] [--pre-push <remote-name> <remote-url>]
       forbid-embabel-upstream.sh --self-test

  (default)  Fail if any remote can push to embabel/guide, or if
             GITHUB_REPOSITORY is embabel/guide.
  --fix
             Disable push on remotes named upstream/embabel whose fetch
             URL is embabel/guide. Fetch stays; push URL becomes DISABLED.
  --pre-push
             Also fail if the hook destination URL is embabel/guide.
  --self-test
             Proving cases: default-push-url-fails, pre-push-url-fails,
             fix-keeps-fetch, fix-disables-push.
EOF
}

check_url() {
  local label="$1"
  local url="$2"
  [[ -z "${url}" ]] && return 0
  if [[ "${url}" =~ ${FORBIDDEN_RE} ]]; then
    echo "FORBIDDEN: ${label} points at embabel/guide: ${url}" >&2
    echo "jmjava/orch-guide is fork-only. Fetch upstream read-only; never push/PR there." >&2
    failures=1
  fi
}

disable_fetch_only_push() {
  local name="$1"
  local fetch_url push_url
  fetch_url="$(git -C "$ROOT" remote get-url "${name}" 2>/dev/null || true)"
  [[ -z "${fetch_url}" ]] && return 0
  [[ "${fetch_url}" =~ ${FORBIDDEN_RE} ]] || return 0
  push_url="$(git -C "$ROOT" remote get-url --push "${name}" 2>/dev/null || true)"
  if [[ -n "${push_url}" && "${push_url}" =~ ${FORBIDDEN_RE} ]]; then
    git -C "$ROOT" remote set-url --push "${name}" DISABLED
    echo "Disabled push URL for remote '${name}' (fetch remains ${fetch_url})" >&2
  fi
}

apply_fix() {
  local name
  while read -r name; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == "upstream" || "${name}" == "embabel" ]]; then
      disable_fetch_only_push "${name}"
    fi
  done < <(git -C "$ROOT" remote 2>/dev/null || true)
}

run_checks() {
  failures=0
  cd "$ROOT"

  # Remotes: reject any push URL (or fetch URL used as push) targeting embabel/guide.
  while read -r name; do
    [[ -z "${name}" ]] && continue
    push_url="$(git remote get-url --push "${name}" 2>/dev/null || true)"
    fetch_url="$(git remote get-url "${name}" 2>/dev/null || true)"
    check_url "remote.${name}.pushurl" "${push_url}"
    # Allow fetch-only upstream named "upstream" / "embabel" if push URL is disabled.
    if [[ "${name}" == "upstream" || "${name}" == "embabel" ]]; then
      if [[ -n "${push_url}" && "${push_url}" == "${fetch_url}" && "${fetch_url}" =~ ${FORBIDDEN_RE} ]]; then
        echo "FORBIDDEN: remote '${name}' can push to embabel/guide (push URL equals fetch URL)." >&2
        echo "Fix: ./scripts/forbid-embabel-upstream.sh --fix" >&2
        echo "  or: git remote set-url --push ${name} DISABLED" >&2
        failures=1
      fi
    else
      check_url "remote.${name}.url" "${fetch_url}"
    fi
  done < <(git remote 2>/dev/null || true)

  # pre-push hook args: $1 = remote name, $2 = remote URL
  if [[ "${1:-}" == "--pre-push" ]]; then
    remote_name="${2:-}"
    remote_url="${3:-}"
    check_url "pre-push remote ${remote_name}" "${remote_url}"
  fi

  # CI / manual: also scan for accidental gh target hints in env
  if [[ "${GITHUB_REPOSITORY:-}" == "embabel/guide" ]]; then
    echo "FORBIDDEN: GITHUB_REPOSITORY is embabel/guide — wrong repo for this fork workflow." >&2
    failures=1
  fi

  if (( failures )); then
    return 1
  fi

  echo "OK: no embabel/guide push/PR target configured"
  return 0
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

self_test() {
  local tmp script
  # A caller (or Cursor/agent) GIT_DIR must not shadow the work tree under test.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  script="${SCRIPT_ROOT}/scripts/forbid-embabel-upstream.sh"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' RETURN

  git init -q "${tmp}"
  # Typical clone leftover: default push URL equals fetch URL == Embabel.
  git -C "${tmp}" remote add upstream https://github.com/embabel/guide.git

  echo "== proving: default-push-url-fails =="
  expect_fail "default-push-url-fails" \
    env FORBID_GIT_ROOT="${tmp}" "${script}"

  echo "== proving: pre-push-url-fails =="
  expect_fail "pre-push-url-fails" \
    "${script}" --pre-push evil https://github.com/embabel/guide.git

  echo "== proving: fix-keeps-fetch / fix-disables-push =="
  env FORBID_GIT_ROOT="${tmp}" "${script}" --fix
  local fetch_url push_url
  fetch_url="$(git -C "${tmp}" remote get-url upstream)"
  push_url="$(git -C "${tmp}" remote get-url --push upstream)"
  case "${fetch_url}" in
    *embabel/guide*)
      echo "PROVE OK: fix-keeps-fetch"
      ;;
    *)
      echo "PROVE FAIL: fix-keeps-fetch expected fetch to stay embabel/guide, got: ${fetch_url}" >&2
      return 1
      ;;
  esac
  if [[ "${push_url}" != "DISABLED" ]]; then
    echo "PROVE FAIL: fix-disables-push expected DISABLED, got: ${push_url}" >&2
    return 1
  fi
  echo "PROVE OK: fix-disables-push"
  env FORBID_GIT_ROOT="${tmp}" "${script}"

  echo "forbid-embabel-upstream: self-test ok"
}

main() {
  local fix=0
  local filtered=()
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--fix" ]]; then
      fix=1
    else
      filtered+=("${arg}")
    fi
  done
  set -- "${filtered[@]+"${filtered[@]}"}"

  case "${1:-}" in
    -h|--help)
      usage
      ;;
    --self-test)
      self_test
      ;;
    --pre-push|"")
      if (( fix )); then
        apply_fix
      fi
      run_checks "$@"
      ;;
    *)
      echo "forbid-embabel-upstream: unknown argument: $1" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
