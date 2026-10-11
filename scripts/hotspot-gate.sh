#!/usr/bin/env bash
# Fail only when a changed Java or Kotlin file is both complex and in
# the top git change-frequency set. A one-line change in a quiet file
# stays allowed. Existing complex hotspots are printed and do not fail
# the run. Does not raise a complexity ceiling or rewrite a baseline.
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    --create-baseline|--write-baseline|--complex-ccn|--complex-ccn=*)
      echo "refusing to raise the complexity ceiling or rewrite a baseline" >&2
      exit 1
      ;;
    -h|--help)
      echo "usage: $0 [base-ref]" >&2
      echo "Rates Java and Kotlin changes versus HOTSPOT_BASE (default: origin/main)." >&2
      exit 0
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="${HOTSPOT_BASE:-${1:-origin/main}}"
exec python3 "$root/scripts/hotspot_gate.py" --repo "$root" --base "$base"
