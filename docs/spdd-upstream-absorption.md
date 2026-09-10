# SPDD / context-graph fork posture (not an Embabel contribution queue)

Audience: agents and humans working on `jmjava/guide` or `jmjava/orch-guide`.

Paired research: orchestrator Work ID
`SPIKE-003-embabel-context-graph-absorption`.

## Hard rule

**Never ask Embabel to merge.** Never open a PR/MR against `embabel/guide`.

**Durable home:** SPDD/dogfood Guide work lives on standalone
**[`jmjava/orch-guide`](https://github.com/jmjava/orch-guide)**.
`jmjava/guide` stays an Embabel fork whose Cloud Agent env **bridges** to
orch-guide (`ensure-orch-guide.sh`, PRs
[#11](https://github.com/jmjava/guide/pull/11)–[#14](https://github.com/jmjava/guide/pull/14)).
Orchestrator dogfood already targets orch-guide
([PR #128](https://github.com/jmjava/sdlc-spdd-orchestrator/pull/128), merged
2026-08-08).

`embabel/guide` is **fetch-only**. Do not push, open a PR, or treat a leftover
“hard-reset this fork to Embabel” note as a contribution path.

See orchestrator
[`docs/guide-flow.md`](https://github.com/jmjava/sdlc-spdd-orchestrator/blob/main/docs/guide-flow.md).

Enforcement (both repos):

| Layer | Mechanism |
|-------|-----------|
| Agent | `.cursor/rules/no-embabel-upstream.mdc` (`alwaysApply`) |
| Git | `scripts/forbid-embabel-upstream.sh` + `scripts/install-git-hooks.sh` |
| CI | `.github/workflows/forbid-embabel-upstream.yml` |

## Current posture (2026-09-10)

| Home | Contents |
|------|----------|
| `jmjava/orch-guide` `main` | Durable SPDD/dogfood Guide + Cloud Agent env |
| `jmjava/guide` `main` | Embabel fork + bridge scripts that clone/run orch-guide |
| `embabel/guide` `main` | Read-only upstream baseline (fetch/merge **in**, never PR **out**) |

**Decision (Accepted):** keep the SPDD context-graph package **and**
git-incremental / RAG maintenance on `jmjava/guide` / `jmjava/orch-guide`.
Do **not** treat any slice as an Embabel merge request. Cloud Agent `.cursor/*`
env files stay fork-local (real env on orch-guide; thin bridge on `jmjava/guide`).

### FEAT-013 status

- Layer B (git-incremental + RAG maintenance) lives on the fork (also isolated on
  branch `cursor/feat-013-layer-b-upstream-f564` for reviewability only).
- **No Embabel PR** — by policy, not as a temporary blocker.
- Work ID closes as **fork-only complete**.

## What stays on the fork

- Entire `com.embabel.guide.spdd` package (`spdd_*` MCP, projection HTTP).
- Git-incremental directory ingest + RAG maintenance operator APIs.
- Ops hardening that exists for dogfood (Neo4j auth alignment, Persona resilience, etc.).
- Cloud Agent `.cursor/*` install/start scripts (orch-guide) and the
  `jmjava/guide` → orch-guide bridge.

## Sync process (inbound only)

1. `git fetch upstream main` (push URL for `upstream` must be `DISABLED`).
2. Merge/rebase **into** `jmjava/guide` or `jmjava/orch-guide` only.
3. Re-run SPDD unit tests + smoke projection if the graph contract moved.
4. Cut a successor pin tag when the orchestrator dogfood pin should move.

```bash
# one-time per clone
./scripts/install-git-hooks.sh
git remote add upstream https://github.com/embabel/guide.git   # if missing
git remote set-url --push upstream DISABLED
./scripts/forbid-embabel-upstream.sh
```

## Explicit non-goals

- Do not open PRs to `embabel/guide` (small or large).
- Do not ask humans “should we upstream this?”
- Do not force SPDD conventions into Embabel defaults via contribution.
- Do not collapse this work into local-LLM / embedding-format experiments.
