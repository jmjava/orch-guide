#!/usr/bin/env bash
# Run PIT on this module, bounded to the ingestion result types.
# Every mutant must be killed. There is no survived ceiling to raise.
# Does not refresh the detekt or SpotBugs baselines.
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    --ceiling|--threshold|--write-baseline)
      echo "refusing to raise the mutation ceiling" >&2
      exit 1
      ;;
    -h|--help)
      echo "usage: $0" >&2
      echo "Runs PIT on IngestionResult and IngestionFailure, then requires every mutant killed." >&2
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# test-compile stops before the test phase. PIT skips the module
# when Maven is told to skip the test run, and still exits 0.
mvn -B -U test-compile org.pitest:pitest-maven:mutationCoverage
python3 "${ROOT}/scripts/pit_mutation.py"
