# Offline Semantic Search for Podcast Transcripts

## The constraint that shapes everything

Marco's app already has two things worth protecting:

1. **Transcribe once, serve many** — 40 M4 Mac Minis transcribe each episode a single time; every listener gets the same transcript. Any search feature should preserve this economics: don't do per-user or per-query server work.
2. **A lightweight SQLite-backed client** — no vector DB, no server extension, no new persistence layer. Whatever search index the client needs has to fit in the storage and query patterns SQLite already supports (plain tables, BLOB columns, linear scans).

That rules out a hosted vector-search service (defeats offline + adds per-query server cost) and rules out swapping in `sqlite-vec` or similar (extra native dependency, cross-compilation for iOS, and a new moving part in the client). It leaves: **compute the expensive part once, on the farm, and ship a small enough result that the client can brute-force it.**

This is the same shape as the `nomic-embed-text` + FTS5 hybrid search already running in [NotesMCP](../NotesMCP) — chunk + embed once, store vectors, compare at query time — except there Ollama embeds the *query* live on every search (server-side, always-on daemon). On iOS there's no Ollama; the equivalent step needs an on-device model small enough to run in an app. That's the one new capability this design requires.

## Architecture

```
Mac Mini farm (per episode, once)              iOS client (per query, offline)
─────────────────────────────────────          ─────────────────────────────────
1. Transcribe (existing pipeline)               1. Sync pulls new/changed chunks
2. Chunk transcript (sentence/time-windowed)        (incremental, cursor-based)
3. Embed each chunk (MLX, nomic-embed-text)     2. Store chunks + fp16 vectors
4. Quantize + attach to sync payload                as BLOBs in existing SQLite
5. Serve via existing distribution path         3. On search: embed query on-device
                                                    (same MLX model, "search_query: " prefix)
                                                 4. Brute-force cosine vs. stored
                                                    chunk vectors (Accelerate/vDSP)
                                                 5. Rank, jump to chunk's timestamp
```

Nothing server-side changes per-query — embedding happens once at transcription time and is amortized across every listener, same as transcription itself. Nothing client-side needs a new storage engine — chunks and vectors ride in tables next to whatever SQLite schema already holds transcripts.

## 1. Chunking (server, once per episode)

Chunk by sentence boundaries within a target window (e.g. 200–400 characters, ~20–45 seconds of speech), not fixed token counts — transcript segments already carry word/phrase-level timestamps from the transcription step, so each chunk can carry a `(start_time, end_time)` pair for free. That's what lets a search hit jump straight to the right moment in playback, which is the actual product feature — text search is a means to "find the part where they talked about X."

Keep a small overlap (one sentence) between consecutive chunks so a topic mentioned right at a chunk boundary isn't split across two low-scoring halves.

## 2. Embedding (server, once per episode)

Use an MLX port of `nomic-embed-text-v1.5`:

- Check `mlx-community` on Hugging Face for an existing converted checkpoint first.
- Otherwise, convert from `nomic-ai/nomic-embed-text-v1.5` HF safetensors using `mlx-embeddings`.
- 768 dimensions, fp16 storage (not fp32) — halves payload size with negligible cosine-similarity accuracy loss. Quantizing further to int8 is possible but adds a dequantization step on both ends for a smaller win than fp16 already gets you; not worth it until payload size is a proven problem.
- **Nomic's prompt-prefix convention must be preserved exactly**: chunks are embedded with the `"search_document: "` prefix, queries with `"search_query: "`. This isn't cosmetic — nomic-embed-text was trained asymmetrically for retrieval, and getting the prefix wrong (or inconsistent between server and client) will silently degrade relevance without throwing an error. This is a correctness requirement, not a tuning knob.
- Tokenizer must match exactly between server (whatever converts the HF checkpoint) and client (`swift-transformers`' WordPiece tokenizer). Mismatched tokenization is a much more common and much harder-to-diagnose failure mode than quantization drift — cosine similarity tolerates numeric drift fine; it does not tolerate two different token streams being embedded as if they were the same text.

This step runs on the same Mac Minis right after transcription, using the same "on-device model, no cloud cost" philosophy already proven out for transcription.

## 3. Payload format

Extend the existing transcript sync payload with a `chunks` array — no new distribution channel:

```json
{
  "episode_id": "abc123",
  "transcript_version": 3,
  "chunks": [
    {
      "chunk_id": "abc123-0042",
      "start_ms": 812400,
      "end_ms": 838900,
      "text": "...",
      "embedding": "<base64 fp16[768]>",
      "content_hash": "sha256:...",
      "updated_at": "2026-08-01T12:00:00Z"
    }
  ]
}
```

- `embedding`: base64-encoded fp16 array — 768 × 2 bytes = 1536 bytes/chunk. A one-hour episode chunked at ~30s/chunk is ~120 chunks ≈ 180KB of embedding data, alongside text that's already being shipped.
- `content_hash` + `updated_at`: reuse whatever change-detection the server already does for transcript indexing, so sync can be **incremental** — client requests "chunks changed since cursor X," not a full re-pull. This matters more for corrections/re-transcriptions than for new episodes, but it's the same mechanism either way.

## 4. Client storage (SQLite, unchanged engine)

Two new tables, no new extension:

```sql
CREATE TABLE transcript_chunks (
    chunk_id      TEXT PRIMARY KEY,
    episode_id    TEXT NOT NULL,
    start_ms      INTEGER NOT NULL,
    end_ms        INTEGER NOT NULL,
    text          TEXT NOT NULL,
    embedding     BLOB NOT NULL,   -- fp16[768], 1536 bytes
    content_hash  TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);
CREATE INDEX idx_chunks_episode ON transcript_chunks(episode_id);

-- optional: free keyword search using iOS's bundled SQLite FTS5
CREATE VIRTUAL TABLE transcript_fts USING fts5(text, content='transcript_chunks', content_rowid='rowid');
```

FTS5 ships in iOS's SQLite already — a keyword-match fallback/complement costs nothing extra to add and is worth it as a hybrid signal (exact term match catches names/jargon that embeddings sometimes blur).

## 5. On-device query

1. Embed the query text with the same MLX model, `"search_query: "` prefix, fp16 output.
2. `SELECT chunk_id, embedding FROM transcript_chunks WHERE episode_id = ?` (or `WHERE episode_id IN (downloaded_ids)` for cross-episode search) — a normal SQLite read, embeddings come back as BLOBs.
3. Brute-force cosine similarity in Swift using `Accelerate`/`vDSP` batched dot products. No ANN index needed:
   - Single episode: a few hundred chunks — sub-millisecond.
   - Cross-episode over a user's downloaded/kept library: even at tens of thousands of chunks, flat fp16/fp32 cosine via `vDSP` is single-digit milliseconds. This is the same conclusion the NotesMCP-adjacent design conversation reached independently — brute force comfortably covers personal-scale corpora, and cross-compiling something like `sqlite-vec` or reaching for `usearch` is only worth revisiting if a corpus genuinely outgrows that (rough rule of thumb: high hundreds of thousands of chunks).
4. Rank top-k, return `(chunk_id, score, start_ms)`, jump playback to `start_ms`.

## Search scope: two tiers, one mechanism

- **Within an episode** (always available): scan is trivial, no storage concern — every synced episode's chunks are already local.
- **Across a user's library** (opt-in, bounded): only keep chunk embeddings for episodes the user has downloaded or explicitly kept. This bounds `transcript_chunks` growth to something a user already chose to store locally (they already accepted the audio file's disk cost, which dwarfs 1536 bytes/chunk). Evict a downloaded episode's audio → evict its chunks in the same pass. No separate storage budget to design — it rides on the existing download/retention lifecycle.

## Neural Engine vs. GPU: MLX doesn't get you there

Marco's ask, reasonably: use the M4's Neural Engine (ANE) for embedding, both on the Mac Mini farm and on iOS devices, for speed and power efficiency. Worth being precise here, because MLX doesn't deliver this:

- **MLX targets the GPU** (via Metal), not the ANE. It's excellent for the farm side — the Mac Minis are plugged in, GPU throughput is the right optimization target, and MLX's ease of loading/converting HF checkpoints is a real advantage there. But "MLX embedding" and "Neural Engine embedding" are not the same thing, on macOS or iOS.
- **Core ML is the only Apple framework that dispatches to the ANE**, and even then indirectly — Core ML's scheduler picks CPU/GPU/ANE per-op at runtime based on the model graph, memory pressure, and what's already running; you request `.all` compute units and it decides, not you.
- Battery-powered iOS is exactly where ANE matters most (perf/watt is the whole point on a phone doing search while the user is also playing audio). The Mac Mini farm is plugged into wall power, so ANE there is a nice-to-have for thermals/rack density, not a requirement — GPU throughput via MLX is a fine choice for the farm regardless of what the client does.

**Practical implication for the architecture:** the two sides don't have to use the same runtime, as long as they produce numerically-equivalent embeddings from the same underlying weights:

- **Server (Mac Mini farm):** MLX is a reasonable choice as designed above — GPU-bound, no battery constraint, and MLX's checkpoint-conversion tooling (`mlx-embeddings`) is the more mature path for getting `nomic-embed-text-v1.5` off Hugging Face.
- **Client (iOS):** if ANE utilization is a real requirement (not just nice-to-have), convert the *same* `nomic-embed-text-v1.5` weights to Core ML (`coremltools`) instead of — or in addition to — the MLX Swift path, and request `.cpuAndNeuralEngine`. This changes the client sample's `QueryEmbedder` implementation (Core ML `MLModel` instead of an MLX graph) but nothing else in this design — chunk storage, the sync payload, and the brute-force cosine search are all runtime-agnostic, since they only care about the final float vector, not what produced it.
- **The hazard either way is the same one flagged above, just doubled:** tokenizer parity and the `"search_document: "`/`"search_query: "` prefix convention must match exactly across *whichever two runtimes* end up on each side (MLX↔MLX, or MLX-server↔CoreML-client). A Core ML conversion is a second opportunity to introduce a subtle preprocessing mismatch versus the server, on top of the one already called out for MLX. Budget a tokenizer-parity golden-set test regardless of which path is chosen.
- Query-time embedding on a single short string is cheap enough (a few hundred tokens through a small BERT-sized encoder) that GPU-via-MLX on iOS is also perfectly viable if Core ML conversion turns out to be more friction than it's worth — this is a "nice to have if the ANE path is easy" decision, not a blocking one for the rest of the architecture.

## What this deliberately does not do

- No vector DB, no SQLite extension, no ANN index. Brute-force is fast enough at this scale and keeps the client dependency surface unchanged.
- No per-query server cost. Embedding happens once per chunk, server-side, amortized like transcription already is.
- No new sync channel. Chunks + embeddings ride the existing transcript payload/sync path with incremental cursors.

## Open questions / next steps

- Confirm an `mlx-community` nomic-embed-text checkpoint exists, or budget time for the `mlx-embeddings` conversion + quantization pass.
- MLX Swift needs a BERT-style encoder (nomic-embed-text's architecture) — likely adapted from existing MLX Swift examples rather than written from scratch.
- Validate tokenizer parity (server conversion pipeline vs. `swift-transformers` WordPiece) with a golden set of (text → token ids) pairs before trusting any relevance numbers.
- Decide chunk window size empirically against a few real transcripts — 200–400 chars is a starting point, not a measured optimum.

See [server-sample/](../server-sample) and [client-sample/](../client-sample) for illustrative (not production-ready) code sketches of the chunk+embed step and the client store/query engine.
