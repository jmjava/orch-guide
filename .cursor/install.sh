#!/usr/bin/env bash
# One-time, idempotent bootstrap for the Embabel Guide Cloud Agent environment.
#
# Prepares durable state for the environment snapshot:
#   * Docker packages (best-effort — many Cloud VMs cannot run containers)
#   * Native Neo4j Community tarball under /opt/neo4j (reliable fallback)
#   * Warmed Maven caches + Drivine KSP-generated sources
#
# Per-boot runtime lives in start.sh / environment.json terminals.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 0. Fork-only guard: never push/PR to embabel/guide.
if [[ -x "$REPO_ROOT/scripts/install-git-hooks.sh" ]]; then
  bash "$REPO_ROOT/scripts/install-git-hooks.sh" || true
fi
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url --push upstream DISABLED || true
fi

# 1. System packages: Docker + nested-container deps (best effort).
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker and dependencies..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker.io docker-compose-v2 fuse-overlayfs iptables uidmap curl tar
fi
sudo usermod -aG docker "$USER" 2>/dev/null || true

# 2. Best-effort dockerd (may fail without CAP_NET_ADMIN / FUSE — OK).
timeout 30s bash "$REPO_ROOT/.cursor/ensure-docker.sh" \
  || echo "WARN: dockerd not usable; native Neo4j fallback will be used at start."

# 3. Pre-install native Neo4j tarball into /opt/neo4j (durable; used when Docker fails).
#    start-native-neo4j.sh installs + starts; we stop the daemon before snapshotting.
bash "$REPO_ROOT/scripts/start-native-neo4j.sh" \
  || echo "WARN: native Neo4j install/start during install failed; start.sh will retry."

if [[ -x /opt/neo4j/bin/neo4j ]]; then
  /opt/neo4j/bin/neo4j stop 2>/dev/null || true
fi
# Do not bake a warm Neo4j store into the environment snapshot. Interrupted
# vector-index checkpoints fail recovery on the next boot; start.sh recreates
# a clean store under /opt/neo4j when needed. Re-apply the initial password so
# a bare `neo4j start` (or start.sh) still authenticates as neo4j/brahmsian.
if [[ -x /opt/neo4j/bin/neo4j ]]; then
  rm -rf /opt/neo4j/data /opt/neo4j/run
  mkdir -p /opt/neo4j/data /opt/neo4j/run
  /opt/neo4j/bin/neo4j-admin dbms set-initial-password \
    "${NEO4J_PASSWORD:-brahmsian}" 2>/dev/null || true
fi

# 4. Warm Maven: Drivine KSP codegen + package the runnable JVM jar.
#    Packaging (~300MB jar + ~/.m2) is what makes Guide start fast on later boots
#    from an environment build/snapshot. Prefer package over compile-only.
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY_INGEST_PLACEHOLDER:-dummy-key}}"
echo "Using JAVA_HOME=$JAVA_HOME"
./mvnw -B -DskipTests package
JAR="$(ls -1 "$REPO_ROOT"/target/guide-*-SNAPSHOT.jar 2>/dev/null | head -n1 || true)"
if [[ -n "$JAR" ]]; then
  echo "Packaged Guide JVM artifact: $JAR ($(du -h "$JAR" | awk '{print $1}'))"
else
  echo "ERROR: Guide package did not produce target/guide-*-SNAPSHOT.jar" >&2
  exit 1
fi

# 5. Pre-pull Neo4j image when Docker can actually run containers (best effort).
if timeout 10s sudo docker info >/dev/null 2>&1 \
  && timeout 15s sudo docker run --rm --network none alpine:3.20 true >/dev/null 2>&1; then
  echo "Warming Docker Neo4j image (best effort, 90s cap)..."
  timeout 90s sudo docker compose --profile neo4j pull neo4j \
    || timeout 90s sudo docker pull neo4j:2025.10.1-community-bullseye \
    || echo "WARN: could not pre-pull Neo4j image."
else
  echo "Skipping Neo4j image pull (Docker not usable for containers)."
fi

echo "install.sh complete."
