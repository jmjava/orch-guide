# Branch change summary for Guide developers

Branch: `cursor/spike-spdd-dice-projection-17f4` (tracks upstream `main`).
Audience: developers who work on Guide and want to understand what this branch adds,
why, and what the blast radius is.

**One paragraph:** the branch turns Guide into an optional *hybrid context backend* for
an SDLC workflow: alongside the existing RAG chunk store, an opt-in projection writes
**typed domain entities** (`__Entity__` nodes: `WorkId`, `Canvas`, `Area`, `Decision`,
`Pitfall`, `Pattern`) into the same Neo4j and exposes typed-edge retrieval over HTTP and
MCP. Everything is behind `guide.spdd-projection.enabled` (default **false**); with the
flag off, runtime behavior matches upstream except for the additions listed under
"Cross-cutting" below.

## 1. New package `com.embabel.guide.spdd` (all opt-in)

| Class | Role |
|-------|------|
| `SpddEntityDictionary` | `DataDictionary.fromClasses` over `NamedEntity` domain types in `spdd.domain` — schema + label validation |
| `SpddMarkdownProjectionService` | Parses structured markdown (`spdd/canvas/*.md`, `agent-context/memory/context-index.md`) and persists via `NamedEntityDataRepository.save` + `mergeRelationship` (merge-by-id, idempotent). Read side: `subgraphForWorkId`, `lessonsForArea`, `listByLabel` |
| `SpddProjectionController` | Operator HTTP under `/api/v1/data/spdd-projection` (`load`, `stats`, `work/{workId}`, `area?name=`) with explicit status mapping (400 validation / 404 not found / 409 disabled) |
| `SpddDomainTools` | `@LlmTool` methods exported to MCP as `spdd_*` via `McpToolExport.fromToolObject(ToolObject(...).withPrefix("spdd_"))`; failures return `{"error": …}` JSON |
| `SpddProjectionConfiguration` | Beans: `DrivineNamedEntityDataRepository` wired with the SPDD dictionary + the MCP export. `@ConditionalOnProperty` on the enable flag |

Graph model: `WorkId —canvas→ Canvas`, `WorkId —area→ Area`,
`WorkId —decision/pitfall/pattern→ lesson`, `lesson —about→ Area`. The `about` edge is
what makes lessons retrievable **across** work items by code area.

Hardening baked in: per-request `rootPath` overrides must resolve under
`default-root-path` or configured `allowed-roots` (the load endpoint is on the
permit-all list, so arbitrary filesystem roots are rejected); a malformed source file is
skipped and counted (`skippedFiles`) instead of failing the load; list reads accept only
schema labels and are capped (50 default / 200 max).

Uses only public library APIs (`NamedEntityData`, `NamedEntityDataRepository`,
`RelationshipDirection`, `DataDictionary`). It does **not** touch the DICE proposition
extraction pipeline, and no consumer project names are hardcoded — the coupling is to
the SPDD directory conventions only.

## 2. RAG ingest: git-incremental directories

- `GitIncrementalDirectorySupport` + `GitIngestionRevisionStore` — when
  `guide.git-ingestion.enabled=true`, directory ingest diffs against the last recorded
  git revision and reprocesses only changed files. Subdirectory entries (e.g.
  `repo/spdd/canvas`) are supported: Guide walks up to the `.git` root and scopes the
  diff.
- `DataManager` — hooks the incremental path into `loadReferences()`.
- `RagContentMaintenanceService`, `RagMaintenanceController`,
  `RagMaintenanceExceptionHandler` — operator endpoints for content-element purge
  preview/purge and git revision reset.

## 3. Cross-cutting changes (active regardless of the flag)

- **`GuideProperties`** — new `spddProjection` block (`enabled`, `defaultRootPath`,
  `allowedRoots`) and git-ingestion settings; `application.yml` documents both, defaults
  off.
- **`SecurityConfig`** — permit-all additions: POST `…/spdd-projection/load`,
  `…/git-ingestion/revision/reset`, `…/content-elements/purge{,-preview}`; GET
  `…/spdd-projection/stats`, `…/work/*`, `…/area`. Same local-operator posture as the
  existing `…/data/load-references`.
- **`PersonaSeedingService`** — startup resilience: fails fast with an actionable
  message if the Drivine KSP query DSL is missing from the classpath, and persona
  seeding failures no longer abort startup (RAG/MCP stay available).
- **Build (`pom.xml`)** — `embabel-agent-rag-neo-drivine` pinned to timestamp
  `0.1.2-20260224.010659-19` (newer snapshots require agent 0.4.0; Guide is on
  0.3.5-SNAPSHOT); maven-enforcer rule fails the build early when the KSP-generated
  DSL files are missing instead of dying at runtime.
- **Scripts** — `append-ingest.sh` gains env-driven Neo4j/profile handling;
  `run-mcp-guide-against-hub.sh` added; `application-*-spdd-projection.yml.example`
  profile example under `scripts/user-config/`.

## 4. Tests

- `SpddMarkdownProjectionServiceTest` (16) — projection, idempotent reload, lesson/about
  edges, root allowlist enforcement, blank/unknown input validation, list caps.
- `SpddProjectionControllerTest` (8) — standalone MockMvc against the real service +
  in-memory repository; verifies the 200/400/404 mapping.
- `SpddDomainToolsTest` (8) — MCP JSON contract, `{"error": …}` on bad input.
- `GitIncrementalDirectorySupportTest`, `RagMaintenanceControllerWebMvcTest`,
  `DataManagerControllerWebMvcTest` — incremental ingest + maintenance endpoints.
- Fixture: `src/test/resources/spdd-fixture/` (minimal canvas + context index).

## 5. How to review / try it

1. `git diff upstream/main...HEAD` — ~30 files; the spdd package and rag ingest classes
   are the substance.
2. Operator walkthrough: `docs/spdd-projection-ingest.md` (enable, persist, retrieve,
   MCP tools).
3. Quick sanity: enable the flag against a project following the SPDD layout, then
   `POST …/spdd-projection/load` and `GET …/work/{workId}`.

## 6. Known limitations

- Domain types are first-class Kotlin `NamedEntity` classes in `spdd.domain` registered
  via `DataDictionary.fromClasses`. The persist path still materializes
  `SimpleNamedEntityData` (+ `__Entity__`) for repository writes — that is intentional
  merge-by-id wiring, not a lingering `DynamicType` schema.
- Entity→chunk join (`findChunksForEntity`) exists at the store level but is not exposed
  on the projection API yet.
- `Operation`, session, and domain-keyword entities are declared in the schema roadmap
  but not projected yet.

## 7. Fork-only posture (never Embabel PR)

See **`docs/spdd-upstream-absorption.md`**. Short version:

| Slice | Posture |
|-------|---------|
| `com.embabel.guide.spdd` + `spdd_*` MCP | **Keep on `jmjava/guide` / `jmjava/orch-guide`** |
| Git-incremental directory ingest + RAG maintenance | **Keep on the fork** (FEAT-013 complete; no Embabel PR) |
| Ops hardening / Cloud Agent `.cursor/*` | **Keep on `jmjava/orch-guide`**; `jmjava/guide` is a thin bridge |
| `embabel/guide` | Fetch/merge **in** only — push/PR **out** forbidden |

Guards: `.cursor/rules/no-embabel-upstream.mdc`,
`scripts/forbid-embabel-upstream.sh`, CI workflow.

Orchestrator research lives under Work ID
`SPIKE-003-embabel-context-graph-absorption`.
