#!/usr/bin/env bash
# Fail when detekt or SpotBugs reports a fingerprint that is not frozen.
# Findings already in the baseline are printed and do not fail the run.
# Does not write or refresh a baseline. Does not run PIT.
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    --create-baseline|--write-baseline|-cb)
      echo "refusing to rewrite the static baseline" >&2
      exit 1
      ;;
    -h|--help)
      echo "usage: $0" >&2
      echo "Compares Kotlin detekt and Java SpotBugs findings to the frozen baselines." >&2
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

DETEKT_BASELINE="${ROOT}/config/detekt-baseline.txt"
SPOTBUGS_BASELINE="${ROOT}/config/spotbugs-baseline.txt"
COMPARE="${ROOT}/scripts/static_baseline.py"

if [[ ! -s "${DETEKT_BASELINE}" || ! -s "${SPOTBUGS_BASELINE}" ]]; then
  echo "static baseline: missing frozen fingerprint file" >&2
  exit 1
fi

DETEKT_VERSION="2.0.0-alpha.3"
DETEKT_SHA="dc71f1eb705fa87abac0d63a5ebb51868d6a6e64bc96eaf56cd2c2a889d2491d"
DETEKT_URL="https://github.com/detekt/detekt/releases/download/v${DETEKT_VERSION}/detekt-cli-${DETEKT_VERSION}-all.jar"
DETEKT_CACHE="${DETEKT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/detekt}"
DETEKT_JAR="${DETEKT_CACHE}/detekt-cli-${DETEKT_VERSION}-all.jar"

SPOTBUGS_VERSION="4.9.3"
SPOTBUGS_SHA="d464d56050cf1dbda032e9482e1188f7cd7b7646eaff79c2e6cbe4d6822f4d9f"
SPOTBUGS_URL="https://github.com/spotbugs/spotbugs/releases/download/${SPOTBUGS_VERSION}/spotbugs-${SPOTBUGS_VERSION}.tgz"
SPOTBUGS_CACHE="${SPOTBUGS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/spotbugs}"
SPOTBUGS_TGZ="${SPOTBUGS_CACHE}/spotbugs-${SPOTBUGS_VERSION}.tgz"
SPOTBUGS_BIN="${SPOTBUGS_CACHE}/spotbugs-${SPOTBUGS_VERSION}/bin/spotbugs"

mkdir -p "$DETEKT_CACHE" "$SPOTBUGS_CACHE"
if [[ ! -f "$DETEKT_JAR" ]] || ! echo "${DETEKT_SHA}  ${DETEKT_JAR}" | sha256sum -c - >/dev/null 2>&1; then
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$DETEKT_URL"
  echo "${DETEKT_SHA}  ${tmp}" | sha256sum -c -
  mv "$tmp" "$DETEKT_JAR"
fi
if [[ ! -x "$SPOTBUGS_BIN" ]] || [[ ! -f "$SPOTBUGS_TGZ" ]] || ! echo "${SPOTBUGS_SHA}  ${SPOTBUGS_TGZ}" | sha256sum -c - >/dev/null 2>&1; then
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$SPOTBUGS_URL"
  echo "${SPOTBUGS_SHA}  ${tmp}" | sha256sum -c -
  mv "$tmp" "$SPOTBUGS_TGZ"
  tar -xzf "$SPOTBUGS_TGZ" -C "$SPOTBUGS_CACHE"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
detekt_report="${workdir}/detekt-checkstyle.xml"
spotbugs_report="${workdir}/spotbugs.xml"
classpath_file="${workdir}/classpath.txt"

echo "static baseline: detekt ${DETEKT_VERSION}"
set +e
java -jar "$DETEKT_JAR" \
  --input src/main/kotlin:src/test/kotlin \
  --base-path "$ROOT" \
  --language-version 2.3 \
  --jvm-target 21 \
  --build-upon-default-config \
  --excludes '**/build/**,**/.gradle/**,**/target/**' \
  --fail-on-severity Never \
  --report "checkstyle:${detekt_report}"
detekt_status=$?
set -e
if [[ "$detekt_status" -ne 0 || ! -s "$detekt_report" ]]; then
  echo "detekt failed to analyze Kotlin sources" >&2
  exit 1
fi

echo "static baseline: compiling Java sources for SpotBugs"
mvn -B -DskipTests test-compile
mvn -B -q dependency:build-classpath -DincludeScope=test -Dmdep.outputFile="${classpath_file}"

java_classes() {
  local src_root="$1"
  local out_root="$2"
  local java rel base dir name class_file
  while IFS= read -r java; do
    rel="${java#"${src_root}/"}"
    base="${rel%.java}"
    dir="$(dirname "$base")"
    name="$(basename "$base")"
    class_file="${out_root}/${base}.class"
    if [[ ! -f "$class_file" ]]; then
      echo "spotbugs: missing class file for ${java}" >&2
      exit 1
    fi
    printf '%s\n' "$class_file"
    if [[ -d "${out_root}/${dir}" ]]; then
      find "${out_root}/${dir}" -maxdepth 1 -name "${name}\$*.class" -print | sort
    fi
  done < <(find "$src_root" -name '*.java' | sort)
}

mapfile -t classes < <(java_classes src/main/java target/classes; java_classes src/test/java target/test-classes)
if [[ "${#classes[@]}" -eq 0 ]]; then
  echo "spotbugs: no Java class files" >&2
  exit 1
fi

aux="target/classes:target/test-classes:$(cat "$classpath_file")"
echo "static baseline: SpotBugs ${SPOTBUGS_VERSION} on ${#classes[@]} Java class file(s)"
set +e
"$SPOTBUGS_BIN" -textui -xml:withMessages -output "$spotbugs_report" \
  -auxclasspath "$aux" \
  -sourcepath src/main/java:src/test/java \
  "${classes[@]}"
spotbugs_status=$?
set -e
if [[ ! -s "$spotbugs_report" ]]; then
  echo "spotbugs failed to analyze Java class files (exit ${spotbugs_status})" >&2
  exit 1
fi
if [[ "$spotbugs_status" -ne 0 && "$spotbugs_status" -ne 1 ]]; then
  echo "spotbugs failed to analyze Java class files (exit ${spotbugs_status})" >&2
  exit 1
fi

python3 "$COMPARE" compare --scanner detekt --baseline "$DETEKT_BASELINE" --report "$detekt_report" --root "$ROOT"
python3 "$COMPARE" compare --scanner spotbugs --baseline "$SPOTBUGS_BASELINE" --report "$spotbugs_report" --root "$ROOT"
