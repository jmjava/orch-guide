#!/usr/bin/env bash
# Install repo-local hooks that refuse pushes to embabel/guide.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="${ROOT}/.githooks"
mkdir -p "${HOOKS_DIR}"

cat >"${HOOKS_DIR}/pre-push" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
remote_name="${1:-}"
remote_url="${2:-}"
exec "${ROOT}/scripts/forbid-embabel-upstream.sh" --pre-push "${remote_name}" "${remote_url}"
EOF
chmod +x "${HOOKS_DIR}/pre-push" "${ROOT}/scripts/forbid-embabel-upstream.sh"

git -C "${ROOT}" config core.hooksPath .githooks
echo "Installed core.hooksPath=.githooks (pre-push → forbid-embabel-upstream)"

# Same harden Cloud Agent install.sh already does: fetch Embabel, never push.
if [[ -x "${ROOT}/scripts/forbid-embabel-upstream.sh" ]]; then
  bash "${ROOT}/scripts/forbid-embabel-upstream.sh" --fix
fi
