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
# tests). FORBID_GH_DEFAULT overrides the resolved gh nameWithOwner (tests).
# FORBID_CURSOR_RULE overrides the Cursor rule path (tests).
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${FORBID_GIT_ROOT:-$SCRIPT_ROOT}"

FORBIDDEN_RE='github\.com[:/]+embabel/guide(\.git)?(/*)?$'

is_embabel_guide_repo() {
  local raw="${1:-}"
  raw="${raw//$'\r'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ -z "${raw}" ]] && return 1
  case "${raw}" in
    embabel/guide|embabel/guide.git) return 0 ;;
  esac
  [[ "${raw}" =~ ${FORBIDDEN_RE} ]]
}

usage() {
  cat <<'EOF'
Usage: forbid-embabel-upstream.sh [--fix] [--pre-push <remote-name> <remote-url>]
       forbid-embabel-upstream.sh --self-test

  (default)  Fail if any remote can push to embabel/guide, if
             GITHUB_REPOSITORY is embabel/guide, or if gh is missing
             (cannot verify the GitHub CLI default repo).
  --fix
             Disable push on remotes named upstream/embabel whose fetch
             URL is embabel/guide. Fetch stays; push URL becomes DISABLED.
  --pre-push
             Also fail if the hook destination URL is embabel/guide.
  --self-test
             Proving cases: default-push-url-fails, pre-push-url-fails,
             fix-keeps-fetch, fix-disables-push, missing-gh-fail-closed,
             cursor-rule-alwaysApply, deleting the rule keeps the job red,
             dropping alwaysApply keeps the job red.
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

# Query from SCRIPT_ROOT so FORBID_GIT_ROOT remote fixtures do not change
# what `gh` resolves (and --fix stays push-URL-only).
check_gh_default_repo() {
  local viewed="" resolved=""

  if [[ -n "${FORBID_GH_DEFAULT:-}" ]]; then
    viewed="${FORBID_GH_DEFAULT}"
  elif command -v gh >/dev/null 2>&1; then
    viewed="$(cd "${SCRIPT_ROOT}" && gh repo set-default --view 2>/dev/null || true)"
    viewed="${viewed//$'\r'/}"
    if [[ -z "${viewed}" ]]; then
      resolved="$(cd "${SCRIPT_ROOT}" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
      resolved="${resolved//$'\r'/}"
      viewed="${resolved}"
      if [[ -z "${viewed}" ]]; then
        echo "SKIP: gh default repo unset and nameWithOwner could not be queried." >&2
        return 0
      fi
    fi
  else
    echo "FORBIDDEN: gh not on PATH; cannot verify GitHub CLI default repo." >&2
    echo "Install GitHub CLI. Missing gh must not skip this check." >&2
    failures=1
    return 0
  fi

  if is_embabel_guide_repo "${viewed}"; then
    echo "FORBIDDEN: GitHub CLI default repo is embabel/guide (${viewed})." >&2
    echo "Fix: gh repo set-default jmjava/orch-guide  # must be run from this repo" >&2
    failures=1
  fi
}

# Leftover #9: Cursor rule + mechanical guard must stay alwaysApply.
# Deleting the rule or dropping front-matter alwaysApply must fail-closed
# (CI red, visible in review — not silent). Body mentions of alwaysApply
# do not count. FORBID_CURSOR_RULE overrides the path (tests).
check_cursor_rule_always_apply() {
  local cursor_rule="${FORBID_CURSOR_RULE:-${SCRIPT_ROOT}/.cursor/rules/no-embabel-upstream.mdc}"
  if [[ ! -f "${cursor_rule}" ]]; then
    echo "FORBIDDEN: missing Cursor rule ${cursor_rule}" >&2
    echo "Deleting .cursor/rules/no-embabel-upstream.mdc must stay visible (CI red)." >&2
    failures=1
    return 0
  fi
  local fm
  fm="$(awk 'BEGIN{p=0} /^---[[:space:]]*$/{p++; next} p==1{print}' "${cursor_rule}")"
  if ! printf '%s\n' "${fm}" | grep -qE '^[[:space:]]*alwaysApply:[[:space:]]*true[[:space:]]*$'; then
    echo "FORBIDDEN: ${cursor_rule} must set alwaysApply: true in front matter." >&2
    echo "Dropping alwaysApply must stay visible (CI red)." >&2
    failures=1
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

  # GitHub CLI default repo. Forks often resolve `gh pr create` to the parent.
  # Missing `gh` must fail-closed (do not skip). A default/nameWithOwner of
  # embabel/guide must fail. --fix does not set or unset this (push-URL only).
  check_gh_default_repo

  check_cursor_rule_always_apply

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
  env FORBID_GIT_ROOT="${tmp}" FORBID_GH_DEFAULT=jmjava/orch-guide "${script}" --fix
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
  env FORBID_GIT_ROOT="${tmp}" FORBID_GH_DEFAULT=jmjava/orch-guide "${script}"

  echo "== proving: missing-gh-fail-closed =="
  local nogh filtered_path dir missing_out missing_err
  nogh="$(mktemp -d)"
  missing_out="$(mktemp)"
  missing_err="$(mktemp)"
  ln -s "$(command -v git)" "${nogh}/git"
  ln -s "$(command -v bash)" "${nogh}/bash"
  filtered_path=""
  IFS=':'
  for dir in ${PATH}; do
    [[ -z "${dir}" ]] && continue
    [[ -x "${dir}/gh" ]] && continue
    if [[ -z "${filtered_path}" ]]; then
      filtered_path="${dir}"
    else
      filtered_path="${filtered_path}:${dir}"
    fi
  done
  unset IFS
  if env PATH="${nogh}:${filtered_path}" FORBID_GH_DEFAULT= FORBID_GIT_ROOT="${tmp}" \
       "${script}" >"${missing_out}" 2>"${missing_err}"; then
    echo "PROVE FAIL: missing-gh-fail-closed expected a red assertion" >&2
    cat "${missing_err}" >&2
    return 1
  fi
  if ! grep -q 'FORBIDDEN: gh not on PATH' "${missing_err}"; then
    echo "PROVE FAIL: missing-gh-fail-closed should print FORBIDDEN about gh not on PATH" >&2
    cat "${missing_err}" >&2
    return 1
  fi
  if grep -q 'SKIP: gh not on PATH' "${missing_err}"; then
    echo "PROVE FAIL: missing gh must not skip the forbid check" >&2
    return 1
  fi
  echo "PROVE OK: missing-gh-fail-closed"

  # Leftover #9: Cursor rule + mechanical guard must stay alwaysApply.
  # Deleting the rule or dropping alwaysApply must be visible (CI red), not silent.
  echo "== proving: cursor-rule-alwaysApply =="
  local rule wf
  rule="${SCRIPT_ROOT}/.cursor/rules/no-embabel-upstream.mdc"
  wf="${SCRIPT_ROOT}/.github/workflows/forbid-embabel-upstream.yml"
  [[ -f "${rule}" ]] || {
    echo "PROVE FAIL: missing ${rule}" >&2
    return 1
  }
  local rule_fm
  rule_fm="$(awk 'BEGIN{p=0} /^---[[:space:]]*$/{p++; next} p==1{print}' "${rule}")"
  if ! printf '%s\n' "${rule_fm}" | grep -qE '^[[:space:]]*alwaysApply:[[:space:]]*true[[:space:]]*$'; then
    echo "PROVE FAIL: rule front matter must set alwaysApply: true" >&2
    return 1
  fi
  if ! grep -q 'check_cursor_rule_always_apply' "${script}"; then
    echo "PROVE FAIL: forbid script must check the Cursor rule (mechanical guard)" >&2
    return 1
  fi
  if ! grep -q 'FORBID_CURSOR_RULE' "${script}"; then
    echo "PROVE FAIL: forbid script must honor FORBID_CURSOR_RULE so deletion can be proven" >&2
    return 1
  fi
  if ! grep -q 'Cursor rule must stay alwaysApply' "${wf}"; then
    echo "PROVE FAIL: workflow must name the alwaysApply step so deletion is visible in review" >&2
    return 1
  fi
  if ! grep -q 'p==1' "${wf}"; then
    echo "PROVE FAIL: workflow alwaysApply step must parse front matter (body mention is not enough)" >&2
    return 1
  fi
  if grep -q 'continue-on-error' "${wf}"; then
    echo "PROVE FAIL: forbid job must not continue-on-error (missing rule would stay green)" >&2
    return 1
  fi
  echo "PROVE OK: cursor-rule-alwaysApply"

  echo "== proving: deleting the rule keeps the job red =="
  local missing_rule_err gone_dir gone
  missing_rule_err="$(mktemp)"
  if env FORBID_CURSOR_RULE=/tmp/does-not-exist-no-embabel-upstream.mdc \
        FORBID_GH_DEFAULT=jmjava/orch-guide "${script}" \
        >/dev/null 2>"${missing_rule_err}"; then
    echo "PROVE FAIL: missing cursor rule expected a red assertion" >&2
    cat "${missing_rule_err}" >&2
    return 1
  fi
  if ! grep -q 'FORBIDDEN: missing Cursor rule' "${missing_rule_err}"; then
    echo "PROVE FAIL: missing rule must print FORBIDDEN about missing Cursor rule" >&2
    cat "${missing_rule_err}" >&2
    return 1
  fi
  gone_dir="$(mktemp -d)"
  gone="${gone_dir}/no-embabel-upstream.mdc"
  expect_fail "deleted cursor rule file" \
    env FORBID_CURSOR_RULE="${gone}" FORBID_GH_DEFAULT=jmjava/orch-guide "${script}"
  echo "PROVE OK: deleting the rule keeps the job red"

  echo "== proving: dropping alwaysApply keeps the job red =="
  local dropped removed body_only drop_err
  dropped="$(mktemp)"
  cp "${rule}" "${dropped}"
  sed -i 's/^alwaysApply: true/alwaysApply: false/' "${dropped}"
  drop_err="$(mktemp)"
  if env FORBID_CURSOR_RULE="${dropped}" FORBID_GH_DEFAULT=jmjava/orch-guide \
        "${script}" >/dev/null 2>"${drop_err}"; then
    echo "PROVE FAIL: alwaysApply false expected a red assertion" >&2
    cat "${drop_err}" >&2
    return 1
  fi
  if ! grep -q 'alwaysApply: true' "${drop_err}"; then
    echo "PROVE FAIL: alwaysApply: false must mention the alwaysApply: true requirement" >&2
    cat "${drop_err}" >&2
    return 1
  fi
  removed="$(mktemp)"
  grep -v '^alwaysApply:' "${rule}" > "${removed}"
  expect_fail "alwaysApply dropped" \
    env FORBID_CURSOR_RULE="${removed}" FORBID_GH_DEFAULT=jmjava/orch-guide "${script}"
  body_only="$(mktemp)"
  cat >"${body_only}" <<'EOF'
---
description: Hard rule — never contribute jmjava/orch-guide changes to embabel/guide.
globs:
---

# Body mention of alwaysApply: true must not keep the job green.
EOF
  expect_fail "alwaysApply only in body" \
    env FORBID_CURSOR_RULE="${body_only}" FORBID_GH_DEFAULT=jmjava/orch-guide "${script}"
  echo "PROVE OK: dropping alwaysApply keeps the job red"

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
