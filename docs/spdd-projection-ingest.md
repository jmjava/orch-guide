# SPDD leg 3 entity projection (SPIKE-001) — DICE persist/retrieve contract

Projects SPDD artifacts — REASONS canvases plus the storage v3 JSONL lessons ledger —
into Neo4j `__Entity__` nodes via `NamedEntityDataRepository`. **Coexists** with leg 2
RAG chunk ingest (`guide.directories`).

Does **not** use the DICE proposition extraction pipeline (conversation → propositions).

The files on disk (`spdd/memory/lessons.jsonl` + canvas markdown) remain **source of
truth**. Projection is the write path into domain memory; domain-graph walk is the
preferred read path for auditable context selection.

## Enable

```yaml
guide:
  spdd-projection:
    enabled: true
    default-root-path: /home/ubuntu/github/jmjava/sdlc-spdd-orchestrator
    # Optional. Roots a per-request rootPath override may resolve under, in addition
    # to default-root-path. Anything else → HTTP 400 (load is on the permit-all list).
    allowed-roots: []
```

Or per-request `rootPath` on load (subject to the allowed-roots guard).

**Effective root:** if the resolved root contains an `sdlc-spdd/` directory (the
orchestrator's single-folder install home), the projection descends into it; otherwise
the root is used as-is. So pointing at a parent workspace that hosts an `sdlc-spdd/`
install works without extra configuration.

Build note: Guide stays on Embabel agent **0.3.5-SNAPSHOT**. Pin
`embabel-agent-rag-neo-drivine` to a pre-`EmbeddingAware` timestamp
(`0.1.2-20260224.010659-19`); newer `0.1.2-SNAPSHOT` jars require agent 0.4.0.

## Persist (write)

```bash
# Project entities from orchestrator (or retrieval-fixture) root
curl -s -X POST http://localhost:21337/api/v1/data/spdd-projection/load \
  -H 'Content-Type: application/json' \
  -d '{"rootPath":"/home/ubuntu/github/jmjava/sdlc-spdd-orchestrator"}' | jq .
```

Idempotent: entity `id` values are stable; re-load merges via `save` / `mergeRelationship`.
Malformed source files are skipped and counted in the response's `skippedFiles`; canvases
are processed in sorted order.

Sources (relative to the effective root):

| Path under root | Entities | Relationships |
|-----------------|----------|---------------|
| `spdd/canvas/*.md` | WorkId, Canvas | WorkId —`canvas`→ Canvas |
| `spdd/memory/lessons.jsonl` | Area, Decision, Pitfall, Pattern, Session, Analysis | WorkId —`area`→ Area; WorkId —`decision`/`pitfall`/`pattern`/`session`/`analysis`→ lesson; lesson —`about`→ Area |

The ledger is JSONL — one record per line, `kind` one of `decision`, `pitfall`,
`pattern`, `session`, `analysis` (unknown kinds are skipped). Real example line
(from the test fixture):

```json
{"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:known-pitfalls.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","phase":"code","ts":"2026-07-05T13:00:00Z","title":"idempotency key","body":"Always use idempotency keys on billing retries","source":"known-pitfalls.md","keywords":["billing","retry"],"schema":1}
```

Per record: `id` becomes the entity id (falling back to `kind:work_id:area:source`
when blank), `title` the name, `body` the description (capped at ~500 chars); the full
`body` plus `workId`, `area`, `source`, `phase`, `ts`, and the `keywords` list are
stored as entity properties. Records with a blank `work_id` and malformed JSON lines
are skipped; duplicate lesson ids within one load are deduplicated.

The `about` edges make lessons queryable by code area **across Work IDs** (cross-run
lessons-learned lookup).

## Retrieve (read)

```bash
# Counts by label
curl -s http://localhost:21337/api/v1/data/spdd-projection/stats | jq .

# WorkId subgraph (typed edges — not cosine)
curl -s http://localhost:21337/api/v1/data/spdd-projection/work/SPIKE-001-guide-rag-context-backend | jq .
```

| Endpoint | Role |
|----------|------|
| `GET /api/v1/data/spdd-projection/stats` | Label counts (`workIdCount`, `canvasCount`, `areaCount`, `decisionCount`, `pitfallCount`, `patternCount`, `sessionCount`, `analysisCount`) |
| `GET /api/v1/data/spdd-projection/work/{workId}` | Domain subgraph via `findRelated` (canvas, area, decision, pitfall, pattern, session, analysis) |
| `GET /api/v1/data/spdd-projection/area?name={area}` | Cross-run lessons for a code area via incoming `about`/`area` edges |
| `GET /api/v1/data/spdd-projection/lesson/{*id}` | One lesson by id with the **full untruncated body** (lesson ids contain `/`, hence the `{*id}` wildcard) |
| `GET /api/v1/data/spdd-projection/by-label?label=X&limit=N` | List entities by schema label (default 50, max 200) |

HTTP responses are **untruncated** — the caps and description truncation below apply to
MCP tools only.

Status mapping: validation failures (bad root, blank workId/area, unknown label) → 400
with `{"error": …}`; unknown workId/area/lesson id → 404; feature disabled → 409.

**MCP (leg 3):** when `guide.spdd-projection.enabled=true`, Guide SSE also exports:

| Tool | Role |
|------|------|
| `spdd_workSubgraph` | Same as `GET …/work/{workId}` |
| `spdd_projectionStats` | Same as `GET …/stats` |
| `spdd_findByLabel` | List `__Entity__` nodes by label (schema labels only) |
| `spdd_areaLessons` | Same as `GET …/area?name=…` — prior lessons before touching an area |
| `spdd_getLesson` | Fetch one lesson by id with the full untruncated body |

MCP working-store discipline: list payloads are capped at **20 items per list by
default, 100 max** (via the `limit` parameter), and entity descriptions are truncated
at **300 chars** with the marker `… [truncated — fetch by id]`. Follow up with
`spdd_getLesson(id)` (or the `lesson/{*id}` HTTP endpoint) when the full text is needed.

Tool failures return `{"error": …}` JSON instead of protocol errors.

Implemented in `SpddDomainTools` (`@LlmTool`) + `McpToolExport` in `SpddProjectionConfiguration`.
Complements `docs_*` chunk tools. After adding tools, reload the Cursor `embabel-dev` MCP
server so the client refreshes its tool list.

**Chunk join:** store-level `findChunksForEntity` can link entity → RAG chunks; not yet on
this controller.

## Typical flow (both legs)

1. **Leg 2** — `./scripts/append-ingest.sh` (menke-5 profile) → RAG chunks  
2. **Leg 3** — `POST /api/v1/data/spdd-projection/load` → WorkId, Canvas, Area, …  
3. **Verify** — stats + `GET …/work/{workId}`

Re-run leg 3 after lessons-ledger/canvas changes. Leg 2 git incremental handles chunk
updates separately.

## Implementation package

`com.embabel.guide.spdd`:

- `domain/SpddDomain.kt` — first-class `NamedEntity` types (`WorkId`, `Canvas`, `Area`, `Decision`, `Pitfall`, `Pattern`, `Session`, `Analysis`, …) with `@Semantics`
- `SpddEntityDictionary` — `DataDictionary.fromClasses("sdlc-spdd", …)` (Embabel-standard; not `DynamicType`)
- `SpddMarkdownProjectionService` — canvas + lessons.jsonl parse, persist, `subgraphForWorkId` / `lessonsForArea` / `getLesson`
- `SpddProjectionController` — operator HTTP
- `SpddDomainTools` — MCP `spdd_*` retrieve tools (`@LlmTool`)
- `SpddProjectionConfiguration` — `DrivineNamedEntityDataRepository` + MCP export beans

## Branch

Originally developed on `cursor/spike-spdd-dice-projection-17f4` (pair with orchestrator
`cursor/spike-guide-ingest-agent-context-17f4`). Projection v3 (JSONL lessons ledger,
Session/Analysis entities, MCP caps, `spdd_getLesson`) lands on `spdd-projection-v3`.
