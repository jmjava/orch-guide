# Cloud Agent env notes (`jmjava/orch-guide`)

Audience: agents and humans who land in a **Cloud Agent** (or local) checkout of
[`jmjava/orch-guide`](https://github.com/jmjava/orch-guide).

**Cloud-agent env notes stay on this fork.** This document is **fork-local**.
**Do not PR Embabel.** Never open a PR, push, or set a push URL to
`github.com/embabel/guide`. Fetch Embabel **in** only.

## What this env is

`jmjava/orch-guide` is the durable SPDD/dogfood Guide home. Real Docker /
native-Neo4j / Maven package work lives **here**. [`jmjava/guide`](https://github.com/jmjava/guide)
stays an Embabel-aligned fork whose `.cursor/*` scripts are a thin bridge into
this repo. Do not copy Cloud Agent env notes into Embabel.

| File | Role |
|------|------|
| `.cursor/environment.json` | Env name, install/start, `guide-app` terminal, ports |
| `.cursor/install.sh` | Harden **this** clone, Docker/native Neo4j, Maven package |
| `.cursor/start.sh` | Reconcile Neo4j (Compose when containers work; native fallback) |
| `.cursor/run-guide-app.sh` | Launch Guide (fat jar preferred; SPDD when orchestrator is present) |
| `.cursor/ensure-docker.sh` | Best-effort dockerd; never block boot |

`.cursor/environment.json` lists `github.com/jmjava/sdlc-spdd-orchestrator`
under `repositoryDependencies` so Cloud Agent can place it at
`/agent/repos/sdlc-spdd-orchestrator`. `run-guide-app.sh` then enables
SPDD projection against that tree.

## Harden this clone

Cloud Agent `install.sh` on **this** repo must keep working even when the
personal env lists only `jmjava/orch-guide`. It:

1. Runs `scripts/install-git-hooks.sh` (pre-push → `forbid-embabel-upstream.sh`,
   and **`--fix`** so `upstream` / `embabel` remotes cannot push).
2. Sets `git remote set-url --push upstream DISABLED` when that remote exists.

Local / agent clones that never run Cloud Agent install should still run:

```bash
./scripts/install-git-hooks.sh
./scripts/forbid-embabel-upstream.sh
```

`install-git-hooks.sh` disables a live `embabel/guide` push URL on remotes
named `upstream` or `embabel`. Fetch from Embabel stays allowed.

## Ports

Guide chat/MCP `1337`, research `21337`, Neo4j HTTP `7474`, Bolt `7687`.

## Dogfood pin

Orchestrator dogfood pin: annotated tag **`spdd-projection-v3`** on
`jmjava/orch-guide` `main` (`187d4d4`). Do **not** retag from a leftover
that only documents this env.

## Related

- Posture: [`docs/spdd-upstream-absorption.md`](spdd-upstream-absorption.md)
- Projection contract: [`docs/spdd-projection-ingest.md`](spdd-projection-ingest.md)
- Agent rule: `.cursor/rules/no-embabel-upstream.mdc`
- Guard: `scripts/forbid-embabel-upstream.sh`
