#!/usr/bin/env bash
# Per-boot startup for the Embabel Guide Cloud Agent environment.
#
# Reconciles Neo4j so Guide can connect on bolt://localhost:7687.
# Prefer Docker Compose when containers actually work; fall back to native
# Neo4j under /opt/neo4j when the nested VM lacks CAP_NET_ADMIN / FUSE
# (common Cloud Agent limitation — dockerd dies on iptables/bridge).
#
# The Guide Spring Boot app itself runs as a visible `terminals` entry
# (see .cursor/environment.json).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

neo4j_http_up() {
  curl -sf -o /dev/null http://localhost:7474 2>/dev/null
}

# True only when Docker can run a container end-to-end (not merely start dockerd).
docker_can_run_containers() {
  command -v docker >/dev/null 2>&1 || return 1
  # Keep ensure-docker best-effort and time-bounded; never block boot on it.
  if ! timeout 25s bash "$REPO_ROOT/.cursor/ensure-docker.sh" >/tmp/guide-ensure-docker.log 2>&1; then
    echo "Docker daemon not usable (see /tmp/guide-ensure-docker.log)."
    return 1
  fi
  # Nested VMs often start dockerd then fail on bridge/iptables/unshare.
  if ! timeout 12s sudo docker run --rm --network none alpine:3.20 true >/tmp/guide-docker-probe.log 2>&1; then
    echo "Docker cannot run containers (see /tmp/guide-docker-probe.log)."
    return 1
  fi
  return 0
}

start_neo4j_docker() {
  echo "Starting Neo4j via Docker Compose..."
  timeout 90s sudo docker compose --profile neo4j up neo4j -d || return 1
  local status="unknown"
  local _
  for _ in $(seq 1 40); do
    if neo4j_http_up; then
      status="$(sudo docker inspect --format '{{.State.Health.Status}}' embabel-neo4j 2>/dev/null || echo http-up)"
      echo "Neo4j ready via Docker (status=$status)."
      return 0
    fi
    sleep 3
  done
  echo "WARN: Docker Neo4j not reachable on :7474." >&2
  return 1
}

start_neo4j_native() {
  echo "Starting native Neo4j (no Docker containers)..."
  bash "$REPO_ROOT/scripts/start-native-neo4j.sh"
}

if neo4j_http_up; then
  echo "Neo4j already responding on :7474 — skipping start."
elif docker_can_run_containers && start_neo4j_docker; then
  :
else
  echo "Using native Neo4j fallback."
  start_neo4j_native
fi

if ! neo4j_http_up; then
  echo "ERROR: Neo4j is not reachable on http://localhost:7474" >&2
  exit 1
fi

echo "start.sh complete."
