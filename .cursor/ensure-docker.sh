#!/usr/bin/env bash
# Idempotently ensure the Docker daemon is running in the Cloud Agent VM.
#
# The Cloud Agent VM is a nested container with no systemd (PID 1 is tini),
# so `systemctl start docker` does not work. We launch dockerd directly.
#
# Many nested VMs lack CAP_NET_ADMIN / FUSE — dockerd then dies on
# iptables/bridge. Callers must treat failure as non-fatal and use the
# native Neo4j fallback.
set -euo pipefail

write_daemon_json() {
  sudo mkdir -p /etc/docker
  # Prefer fuse-overlayfs; disable iptables when the kernel rejects NAT rules.
  cat <<'EOF' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "storage-driver": "fuse-overlayfs",
  "iptables": false,
  "ip6tables": false,
  "bridge": "none"
}
EOF
}

start_dockerd_and_wait() {
  write_daemon_json
  # Clear a half-dead dockerd from a previous attempt.
  sudo pkill -9 dockerd 2>/dev/null || true
  sudo pkill -9 containerd 2>/dev/null || true
  sleep 1
  echo "Starting dockerd..."
  sudo nohup dockerd >/tmp/dockerd.log 2>&1 &
  local _
  for _ in $(seq 1 15); do
    if sudo docker info >/dev/null 2>&1; then
      return 0
    fi
    # Fail fast if the log already shows a fatal init error.
    if grep -qE 'failed to start daemon|Permission denied|operation not permitted' /tmp/dockerd.log 2>/dev/null; then
      return 1
    fi
    sleep 1
  done
  return 1
}

if ! sudo docker info >/dev/null 2>&1; then
  if ! start_dockerd_and_wait; then
    echo "ERROR: dockerd failed to start. Recent log:" >&2
    tail -40 /tmp/dockerd.log >&2 || true
    exit 1
  fi
fi

# Best-effort: let $USER use the socket without sudo (for Testcontainers).
sudo usermod -aG docker "$USER" 2>/dev/null || true
sudo chmod a+rx /run /var/run 2>/dev/null || true
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

echo "Docker is ready (server reachable via sudo)."
if docker info >/dev/null 2>&1; then
  echo "Docker socket is usable by $USER without sudo."
else
  echo "NOTE: $USER should use the docker group (fresh login) or sudo for Docker."
fi
