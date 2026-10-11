#!/usr/bin/env bash
# Run the ArchUnit fitness function: projection code may not call
# embabel/guide push URLs. failIfNoTests keeps the job red if the test
# class is renamed or filtered out.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

exec mvn -U -B test \
  -Dtest=ProjectionPushUrlFitnessTest \
  -DfailIfNoTests=true \
  -Dsurefire.failIfNoSpecifiedTests=true
