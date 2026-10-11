#!/usr/bin/env bash
# Proves a frozen fingerprint passes, a new fingerprint fails, and an empty
# baseline is not a pass. The gate must not rewrite the baseline and must not run PIT.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/static-baseline.sh"
COMPARE="${ROOT}/scripts/static_baseline.py"
WORKFLOW="${ROOT}/.github/workflows/static-baseline.yml"
DETEKT_BASELINE="${ROOT}/config/detekt-baseline.txt"
SPOTBUGS_BASELINE="${ROOT}/config/spotbugs-baseline.txt"

fail() {
  echo "ASSERT FAIL: $*" >&2
  exit 1
}

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"
[[ -f "${COMPARE}" ]] || fail "missing ${COMPARE}"
[[ -f "${WORKFLOW}" ]] || fail "missing ${WORKFLOW}"
[[ -s "${DETEKT_BASELINE}" ]] || fail "missing detekt fingerprint baseline"
[[ -s "${SPOTBUGS_BASELINE}" ]] || fail "missing SpotBugs fingerprint baseline"

if ! grep -qE '^[[:space:]]*static-baseline:[[:space:]]*$' "${WORKFLOW}"; then
  fail "workflow must define job static-baseline"
fi
if ! grep -q 'static-baseline.sh' "${WORKFLOW}"; then
  fail "workflow must invoke static-baseline.sh"
fi
if ! grep -q 'static-baseline-assert.sh' "${WORKFLOW}"; then
  fail "workflow must invoke this assert"
fi
if grep -q 'continue-on-error' "${WORKFLOW}"; then
  fail "static baseline must not continue-on-error"
fi
if grep -qE 'pitest|mutmut|org\.pitest' "${WORKFLOW}" "${SCRIPT}" "${COMPARE}"; then
  fail "static baseline must not run PIT or mutmut"
fi
if grep -qE 'create-baseline|write-baseline|detekt:create-baseline' "${WORKFLOW}"; then
  fail "workflow must not rewrite the baseline"
fi
if grep -E '(>>?|[|]tee)\s+.*baseline' "${SCRIPT}" "${COMPARE}"; then
  fail "gate must not redirect into a baseline file"
fi
if grep -qE 'write_text|Path\([^)]*baseline[^)]*\)\.open' "${COMPARE}"; then
  fail "comparer must not write a baseline file"
fi

echo "== proving: refuses-baseline-rewrite =="
if "${SCRIPT}" --create-baseline >/tmp/static-baseline-assert-out.txt 2>/tmp/static-baseline-assert-err.txt; then
  fail "create-baseline must fail"
fi
if ! grep -q 'refusing to rewrite the static baseline' /tmp/static-baseline-assert-err.txt; then
  fail "baseline rewrite must be refused"
fi
if python3 "${COMPARE}" --write-baseline >/tmp/static-baseline-assert-out.txt 2>/tmp/static-baseline-assert-err.txt; then
  fail "comparer must refuse --write-baseline"
fi
if ! grep -q 'refusing to rewrite the static baseline' /tmp/static-baseline-assert-err.txt; then
  fail "comparer rewrite must be refused"
fi
echo "refuses-baseline-rewrite OK"

before_detekt="$(sha256sum "${DETEKT_BASELINE}")"
before_spotbugs="$(sha256sum "${SPOTBUGS_BASELINE}")"

python3 - "${COMPARE}" "${ROOT}" <<'PY'
import subprocess
import sys
import tempfile
from pathlib import Path

compare_path, root = sys.argv[1:]
sys.path.insert(0, str(Path(compare_path).resolve().parent))
import static_baseline as module

tmp = Path(tempfile.mkdtemp())
detekt_one = tmp / "detekt-one.xml"
detekt_two = tmp / "detekt-two.xml"
detekt_empty = tmp / "detekt-empty.xml"
detekt_baseline = tmp / "detekt-baseline.txt"
empty_baseline = tmp / "empty-baseline.txt"
spotbugs_known = tmp / "spotbugs-known.xml"
spotbugs_new = tmp / "spotbugs-new.xml"
spotbugs_baseline = tmp / "spotbugs-baseline.txt"

error = (
    '<error line="3" column="1" severity="error" message="magic" '
    'source="detekt.MagicNumber" />'
)
detekt_one.write_text(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<checkstyle version=\"4.3\">\n"
    "<file name=\"src/main/kotlin/com/example/Old.kt\">\n"
    f"{error}\n"
    "</file>\n</checkstyle>\n",
    encoding="utf-8",
)
detekt_two.write_text(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<checkstyle version=\"4.3\">\n"
    "<file name=\"src/main/kotlin/com/example/Old.kt\">\n"
    f"{error}\n{error}\n"
    "</file>\n</checkstyle>\n",
    encoding="utf-8",
)
detekt_empty.write_text(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<checkstyle version=\"4.3\">\n</checkstyle>\n",
    encoding="utf-8",
)
empty_baseline.write_text("# empty\n", encoding="utf-8")
frozen = module.load_detekt(detekt_one, Path(root))
detekt_baseline.write_text(module.render_baseline("detekt", frozen), encoding="utf-8")
round_trip = module.parse_baseline(detekt_baseline.read_text(encoding="utf-8"))
if round_trip != {frozen[0].fingerprint: 1}:
    raise SystemExit("detekt baseline render did not round-trip")


def run(report: Path, baseline: Path, scanner: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            compare_path,
            "compare",
            "--scanner",
            scanner,
            "--baseline",
            str(baseline),
            "--report",
            str(report),
            "--root",
            root,
        ],
        text=True,
        capture_output=True,
        check=False,
    )


known = run(detekt_one, detekt_baseline, "detekt")
if known.returncode != 0:
    print(known.stderr, file=sys.stderr)
    raise SystemExit("baselined detekt finding must pass")
if "visible; not a failure" not in known.stdout or "detekt.MagicNumber" not in known.stdout:
    raise SystemExit("baselined detekt finding must stay visible")

raised = run(detekt_two, detekt_baseline, "detekt")
if raised.returncode == 0 or "count 1 -> 2" not in raised.stderr:
    raise SystemExit("a higher detekt count must fail")

empty_with_finding = run(detekt_one, empty_baseline, "detekt")
if empty_with_finding.returncode == 0 or "empty baseline is not a pass" not in empty_with_finding.stderr:
    raise SystemExit("an empty baseline must not pass when detekt has a finding")

empty_without_finding = run(detekt_empty, empty_baseline, "detekt")
if empty_without_finding.returncode == 0 or "empty baseline is not a pass" not in empty_without_finding.stderr:
    raise SystemExit("an empty baseline must not pass when detekt reports nothing")

bug = """<?xml version="1.0" encoding="UTF-8"?>
<BugCollection version="4.9.3">
  <BugInstance type="NP_NULL" instanceHash="{hash}">
    <LongMessage>possible null</LongMessage>
    <SourceLine primary="true" start="4" relSourcepath="main/java/com/example/Old.java"/>
  </BugInstance>
</BugCollection>
"""
spotbugs_known.write_text(bug.format(hash="abc123"), encoding="utf-8")
spotbugs_new.write_text(bug.format(hash="def456"), encoding="utf-8")
frozen_bugs = module.load_spotbugs(spotbugs_known, Path(root))
if frozen_bugs[0].path != "src/main/java/com/example/Old.java":
    raise SystemExit(f"unexpected spotbugs path {frozen_bugs[0].path}")
spotbugs_baseline.write_text(module.render_baseline("spotbugs", frozen_bugs), encoding="utf-8")

known_bug = run(spotbugs_known, spotbugs_baseline, "spotbugs")
if known_bug.returncode != 0:
    print(known_bug.stderr, file=sys.stderr)
    raise SystemExit("baselined SpotBugs finding must pass")
if "visible; not a failure" not in known_bug.stdout or "NP_NULL" not in known_bug.stdout:
    raise SystemExit("baselined SpotBugs finding must stay visible")

new_bug = run(spotbugs_new, spotbugs_baseline, "spotbugs")
if new_bug.returncode == 0 or "NEW src/main/java/com/example/Old.java:4: NP_NULL" not in new_bug.stderr:
    print(new_bug.stdout)
    print(new_bug.stderr, file=sys.stderr)
    raise SystemExit("a new SpotBugs fingerprint must fail")

empty_bug = run(spotbugs_known, empty_baseline, "spotbugs")
if empty_bug.returncode == 0 or "empty baseline is not a pass" not in empty_bug.stderr:
    raise SystemExit("an empty SpotBugs baseline must not pass")
PY

after_detekt="$(sha256sum "${DETEKT_BASELINE}")"
after_spotbugs="$(sha256sum "${SPOTBUGS_BASELINE}")"
if [[ "${before_detekt}" != "${after_detekt}" || "${before_spotbugs}" != "${after_spotbugs}" ]]; then
  fail "assert rewrote a committed baseline"
fi

if ! grep -q 'detekt.CyclomaticComplexMethod' "${DETEKT_BASELINE}"; then
  fail "detekt baseline must freeze a real finding"
fi
if ! grep -q 'NP_NULL_ON_SOME_PATH_FROM_RETURN_VALUE' "${SPOTBUGS_BASELINE}"; then
  fail "SpotBugs baseline must freeze a real finding"
fi
if ! grep -Eq '^[1-9][0-9]* [0-9a-f]{64} ' "${DETEKT_BASELINE}"; then
  fail "detekt baseline must contain sha256 fingerprints"
fi
if ! grep -Eq '^[1-9][0-9]* [0-9a-f]+ ' "${SPOTBUGS_BASELINE}"; then
  fail "SpotBugs baseline must contain fingerprints"
fi

echo "static-baseline-assert OK"
