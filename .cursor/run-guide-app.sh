#!/usr/bin/env bash
# Visible terminal launcher for Cloud Agent Guide (see .cursor/environment.json).
# Prefers the fat jar baked by install.sh; falls back to mvnw spring-boot:run.
# Force Maven: GUIDE_USE_MVN=1
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"

echo "Waiting for Neo4j on :7474..."
until curl -sf -o /dev/null http://localhost:7474; do sleep 3; done

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

SPRING_ARGS=()
if [[ -d /agent/repos/sdlc-spdd-orchestrator ]]; then
  mkdir -p scripts/user-config
  cat > scripts/user-config/application-spdd-dev.yml <<'YAML'
guide:
  reload-content-on-startup: false
  spdd-projection:
    enabled: true
    default-root-path: /agent/repos/sdlc-spdd-orchestrator
    allowed-roots:
      - /agent/repos/sdlc-spdd-orchestrator
  directories: []
  git-ingestion:
    enabled: false
spring:
  neo4j:
    uri: bolt://localhost:7687
    authentication:
      username: neo4j
      password: brahmsian
YAML
  export GUIDE_PROFILE=spdd-dev
  export SPRING_PROFILES_ACTIVE=neo4j,local,spdd-dev
  SPRING_ARGS+=(--spring.config.additional-location=file:./scripts/user-config/)
else
  export SPRING_PROFILES_ACTIVE=neo4j,local
fi

export NEO4J_URI="${NEO4J_URI:-bolt://localhost:7687}"
export NEO4J_USERNAME="${NEO4J_USERNAME:-neo4j}"
export NEO4J_PASSWORD="${NEO4J_PASSWORD:-brahmsian}"

JAR="$(ls -1 "$REPO_ROOT"/target/guide-*-SNAPSHOT.jar 2>/dev/null | head -n1 || true)"
if [[ -n "$JAR" ]] && ! truthy "${GUIDE_USE_MVN:-}"; then
  echo "Launching packaged JVM: $JAR"
  exec java -jar "$JAR" "${SPRING_ARGS[@]}"
fi

echo "No packaged jar (or GUIDE_USE_MVN=1) — using mvnw spring-boot:run"
if [[ ${#SPRING_ARGS[@]} -gt 0 ]]; then
  exec ./mvnw -DskipTests spring-boot:run -Dspring-boot.run.arguments="${SPRING_ARGS[*]}"
fi
exec ./mvnw -DskipTests spring-boot:run
