# Shell scripts

| Script | Purpose |
|---|---|
| `fresh-ingest.sh` | Wipes Neo4j RAG data and re-ingests everything from scratch. Use for first-time setup or when you want a clean slate. |
| `append-ingest.sh` | Re-ingests without clearing existing data. Use when you've added new URLs or directories. Comment out already-ingested items in your profile to avoid re-processing them. |
| `run-mcp-guide-against-hub.sh` | Run Guide on **`$GUIDE_PORT`** (default **1337**) for MCP at **`/sse`**, using the **same external Bolt defaults** as **`USE_EMBABEL_HUB_NEO4J=1`** in `append-ingest.sh` (self-contained script; no extra `lib/`). |
| `shell.sh` | Runs the application in interactive shell mode. |
| `assert-spdd-projection-pin.sh` | Fail-closed check that `refs/tags/spdd-projection-v3` exists and peels to the SHA in `spdd-projection-pin.env`. `--self-test` proves missing-tag and wrong-SHA go red. Does not retag. |
| `forbid-embabel-upstream.sh` | Fail-closed check that no remote can push to `embabel/guide`. `--self-test` proves `default-push-url-fails` and `pre-push-url-fails`. `FORBID_GIT_ROOT` points the remote scan at a throwaway repo. |

Both ingestion scripts load your personal profile and run Guide with reload-on-startup. Watch application logs for ingestion progress. If **`ANTHROPIC_API_KEY`** is not set, `append-ingest.sh` exports a **`dummy-key`** placeholder so Spring starts (Anthropic autoconfigure requires the variable; ingestion embeddings use local ONNX). Put a real key in `.env` when you use Claude.

By default they start **guide** Compose Neo4j (`embabel-neo4j`, Bolt `localhost:7687`). For **any other** Bolt endpoint (different host/port/password), set **`SKIP_COMPOSE_NEO4J=1`** and configure **`NEO4J_URI`**, **`NEO4J_PASSWORD`**, **`NEO4J_PORT`**, etc. The **`append-ingest.sh`** header documents a **`USE_EMBABEL_HUB_NEO4J=1`** shortcut for one common Docker layout; adjust env vars if yours differs. Do **not** point **`fresh-ingest.sh`** at a shared production-style graph (it deletes `ContentElement` nodes).

## Personal profiles

Both scripts read `GUIDE_PROFILE` from `.env` (default: `user`).
Each developer can have their own Spring profile:

```bash
cp scripts/user-config/application-user.yml.example scripts/user-config/application-yourname.yml
# Edit to taste, then:
echo 'GUIDE_PROFILE=yourname' >> .env
./scripts/fresh-ingest.sh
```

This loads `application-yourname.yml` with your URLs, directories, and settings.
See `scripts/user-config/README.md` for full details.

## Using append-ingest.sh

Since `append-ingest.sh` doesn't clear the store, you should comment out URLs and directories that are already ingested in your profile to avoid re-processing them. For example:

```yaml
guide:
  urls:
    # - https://docs.embabel.com/embabel-agent/guide/0.3.5-SNAPSHOT/  # already ingested
    - https://some-new-url.com  # new, will be ingested
  directories:
    # - ~/github/jmjava/guide  # already ingested
    - ~/github/jmjava/new-repo  # new, will be ingested
```

Then run `./scripts/append-ingest.sh`. The new content is added alongside existing data in Neo4j.

## Operator API (shared Neo4j)

When Guide is running, these **`/api/v1/data`** endpoints are open for local/dev use (same security posture as **`load-references`** — do not expose Guide to untrusted networks without a proxy).

| Method | Path | Purpose |
|--------|------|--------|
| `POST` | `/api/v1/data/content-elements/purge-preview` | JSON body: `{ "uriPrefix": "..." }` **or** `{ "directory": "~/path/to/repo" }` (not both). Returns match count + sample `uri`s. Prefix must be ≥ 8 characters. |
| `POST` | `/api/v1/data/content-elements/purge` | Same prefix fields plus `"confirm": true` — **deletes** matching `ContentElement` nodes (`uri STARTS WITH` resolved prefix). |
| `POST` | `/api/v1/data/git-ingestion/revision/reset` | JSON `{ "directory": "~/path" }` — removes that repo’s entry from the git-ingestion revision file (requires `guide.git-ingestion.enabled`). Next ingest does a full tree for that directory. |

**Directory → `file:` URI:** `directory` is resolved like `guide.directories` (`~` expanded). Chunks use that `file:` prefix in Neo4j.

**Examples:**

```bash
curl -s -X POST http://localhost:1337/api/v1/data/content-elements/purge-preview \
  -H 'Content-Type: application/json' \
  -d '{"directory":"~/github/jmjava/dice"}' | jq .

curl -s -X POST http://localhost:1337/api/v1/data/git-ingestion/revision/reset \
  -H 'Content-Type: application/json' \
  -d '{"directory":"~/github/jmjava/dice"}' | jq .
```

## Tips

- **If ingestion seems stuck** on a URL: the thread is blocked on fetch -> parse -> embed. Try lowering `embedding-batch-size` to 20, or temporarily remove the slow URL.
- **Speed up ingestion**: increase `embedding-batch-size` (default 50) or `max-chunk-size` (default 4000).
