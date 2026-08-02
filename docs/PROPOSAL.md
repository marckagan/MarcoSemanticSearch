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

## Why not just SQLite FTS5?

SQLite already ships FTS5 on iOS for free — no dependency, no new code. Worth being direct about what it does and doesn't get you, since this design adds real complexity (a farm-side embedding step, an on-device model) on top of something that already exists.

**What FTS5 is:** a keyword/token index. It matches on the words actually present in the text (with stemming/prefix support), ranked by term frequency (BM25). It's exact-vocabulary matching — fast, zero-dependency, and genuinely good at what it does.

**What FTS5 structurally cannot do:** match on *meaning* when the words differ. A user who searches "sourdough starter dying" will not find the segment where the guest says "my culture kept going flat and smelling like nail polish remover" — there's no shared vocabulary for FTS5 to index against, no matter how the query is stemmed or tokenized. This isn't a tuning problem, it's what token-matching search is. Podcast transcripts are conversational speech, not written prose with consistent terminology — the same topic gets described differently by different guests, in asides, in answer-the-question-without-restating-it style. That's exactly the gap embedding-based search closes: it compares the *meaning* of the query against the *meaning* of each chunk, not the literal tokens.

**Concretely, what this buys over FTS5 alone:**

| | FTS5 alone | + embeddings (this design) |
|---|---|---|
| Exact term / name / jargon match | Yes, and fast | Also yes — the design keeps FTS5 alongside embeddings, not instead of it |
| Paraphrase / conceptual match ("the part about burnout" finds "I was so exhausted I couldn't get out of bed") | No | Yes |
| Ranking by relevance to intent, not just term frequency | No — BM25 only knows term stats | Yes — cosine similarity reflects semantic closeness |
| Works when the user doesn't remember the exact phrase used | No | Yes — this is the common real case for "find that part where..." |

**This design doesn't replace FTS5 — it adds semantic recall on top of it.** The client schema keeps the `transcript_fts` virtual table (see below) specifically so exact-term search stays free and fast; embeddings handle the harder case FTS5 can't reach at all. A production version would likely blend both (hybrid ranking, similar in spirit to the FTS5+vector hybrid already running in NotesMCP) rather than picking one — but even embeddings alone already cover a real, common search failure mode that no amount of FTS5 tuning fixes, because the problem isn't ranking, it's that the words genuinely don't match.

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

Only one framework can reach the ANE at all — Core ML. MLX (and PyTorch/TensorFlow-Metal) can only reach CPU or GPU. So "use MLX" and "use the Neural Engine" are mutually exclusive choices, not two knobs on the same framework. That leaves three real options:

### Option A — MLX everywhere (GPU, both sides)

- **Pros:** one runtime, one conversion pipeline, one thing to keep numerically consistent. `mlx-embeddings` is the most mature path for pulling `nomic-embed-text-v1.5` off Hugging Face today. Least engineering risk.
- **Cons:** no ANE utilization anywhere. On the farm this barely matters (wall power, GPU throughput is already the right target). On iOS it means embedding a query burns GPU cycles instead of the much more power-efficient ANE — worse for battery life on exactly the device where that's supposed to matter.
- **When it's the right call:** if "Neural Engine" was really shorthand for "fast and efficient," not a hard requirement, and query embedding turns out to be cheap enough on GPU that the difference is unmeasurable in practice (plausible — it's a few hundred tokens through a small encoder, likely sub-50ms either way).

### Option B — MLX on the farm, Core ML on iOS (split runtime)

- **Pros:** gets ANE on the device where perf/watt actually matters (phone, on-battery, possibly running while audio is also playing), while keeping the farm on MLX's easier conversion tooling.
- **Cons:** two separate model-conversion pipelines from the same source weights (`mlx-embeddings` for the farm, `coremltools` for the client). That's two chances to introduce a subtle preprocessing mismatch — tokenizer differences, prefix handling, normalization — between server and client. This is the failure mode called out below: it degrades relevance silently, no crash, just worse search results that are hard to root-cause.
- **Mitigation:** a small golden-set test — same 20–30 strings, assert token-id sequences match exactly between whatever tokenizes for MLX and whatever tokenizes for Core ML — run once, before trusting any relevance numbers. Not expensive, just easy to skip and then regret.
- **When it's the right call:** if ANE on iOS is a real product requirement (battery life claims, thermal budget while podcast + search running concurrently), not just "would be nice."

### Option C — Core ML everywhere

- **Pros:** single runtime again, ANE-eligible on both sides (the farm's M4s have ANE too — Core ML's scheduler could use it there as well, though with less benefit than on iOS since power isn't constrained).
- **Cons:** Core ML's HF-to-CoreML conversion tooling (`coremltools`) is less turnkey for a BERT-style embedding model than MLX's path — expect more manual work getting `nomic-embed-text-v1.5` converted and validated. Also, Core ML doesn't let you force ANE — you request `.cpuAndNeuralEngine` and its scheduler decides per-op at runtime based on the graph and what else is running; for a model architecture with unsupported ops it can silently fall back to CPU/GPU with no error.
- **When it's the right call:** if consistency (one pipeline, no cross-runtime drift risk) is valued over conversion ease, and someone's willing to do the more manual Core ML conversion work up front.

### Recommendation

Given the stated priorities — raw performance on the Mac Mini farm, with power and search speed weighted equally on iOS — **Option B is the clear call, not just the pragmatic middle ground:**

- **Farm: performance is the only priority, so GPU-via-MLX is the right target, full stop.** Chunk embedding on the farm is a bulk, batched workload (whole episodes, many chunks at once, no user waiting on a single result) — exactly the profile where GPU throughput wins over ANE. The ANE is optimized for low-latency, low-power *single* inferences, not batch throughput; pushing the farm toward Core ML/ANE would trade away the thing that's actually prioritized there for a benefit (power efficiency) that isn't a farm priority given wall power.
- **iOS: power and speed are weighted equally, and that's not actually a tension for this specific workload — it's a case for ANE, not against it.** Query-time embedding on iOS is the opposite profile from the farm: a single short string (a few hundred tokens), one inference, need the answer as fast as possible without draining the battery. That is precisely the workload Core ML's ANE path is designed for — low latency *and* low power on small single-inference requests, not a tradeoff between the two. GPU-via-MLX would likely be competitive on latency for a workload this small, but it burns more power doing it; since power is an equal-weight priority here (not secondary), that's a real cost, not a rounding error.

So the split in Option B isn't a compromise between two runtimes with different strengths — it's each side independently landing on the runtime that matches its own priority: GPU/MLX for farm throughput, ANE/Core ML for iOS latency-and-power together. The mitigation above (tokenizer-parity golden-set test) is the cost of that split and should be budgeted up front rather than treated as optional, given both sides are now firm requirements rather than one being a "nice to have."

**Practical implication for the architecture either way:** the two sides don't have to use the same runtime, as long as they produce numerically-equivalent embeddings from the same underlying weights. Swapping runtimes only changes the client sample's `QueryEmbedder` implementation (Core ML `MLModel` instead of an MLX graph) — chunk storage, the sync payload, and the brute-force cosine search are all runtime-agnostic, since they only care about the final float vector, not what produced it. The one hazard that applies regardless of which option is chosen: tokenizer parity and the `"search_document: "`/`"search_query: "` prefix convention must match exactly across whichever two runtimes end up on each side.

## What this deliberately does not do

- No vector DB, no SQLite extension, no ANN index. Brute-force is fast enough at this scale and keeps the client dependency surface unchanged.
- No per-query server cost. Embedding happens once per chunk, server-side, amortized like transcription already is.
- No new sync channel. Chunks + embeddings ride the existing transcript payload/sync path with incremental cursors.

## Is this fully open source? What's not code Marco owns?

**Yes — every piece of this, end to end, is either open source or a free Apple system framework already on the device. No commercial software, no paid API, no license fee anywhere in the pipeline.** But "open source" and "code you own" aren't the same thing — everything below is a third-party dependency of one kind or another, even where it costs nothing. Worth listing plainly, since Marco prefers to limit third-party dependencies and should know exactly what's being taken on and where.

| Component | Role | License | Owned by Marco? | Shipped at runtime? |
|---|---|---|---|---|
| SQLite + FTS5 | Storage, keyword search | Public domain | No — OS-bundled | Yes, client (already true today, unchanged) |
| Accelerate / vDSP | Cosine similarity math | Apple system framework (proprietary, free) | No — OS-bundled | Yes, client |
| Core ML | ANE-eligible inference (Option B/C) | Apple system framework (proprietary, free) | No — OS-bundled | Yes, client |
| MLX / MLX Swift | GPU inference, model loading | MIT (open source) | No — third-party Swift package | Yes, farm (both options); client only under Option A |
| `swift-transformers` (Hugging Face) | WordPiece tokenizer, client side | Apache-2.0 (open source) | No — third-party Swift package | Yes, client |
| `nomic-embed-text-v1.5` weights | The embedding model itself | Apache-2.0 (open source) | No — third-party model weights | Yes, both sides (as a bundled model file, not code) |
| `mlx-embeddings` (community, Prince Canuma) | HF → MLX weight conversion | **GPLv3** | No — third-party tool | No — build/conversion-time only, not linked into anything shipped |
| `coremltools` (Apple) | HF → Core ML weight conversion (Option B/C) | BSD-3-Clause (open source) | No — third-party tool | No — build/conversion-time only |

Two things worth flagging directly:

- **Everything actually shipped at runtime (client app or farm service) is either public-domain, MIT, Apache-2.0, or an Apple system framework that's already part of the OS.** No AGPL, no viral copyleft, nothing that imposes obligations on Marco's own app code.
- **The one license worth a second look is `mlx-embeddings`, which is GPLv3** — a copyleft license, stricter than everything else in this list. It's only used as an offline conversion tool (HF checkpoint → MLX format), run once on a build machine, never linked into the farm service or the iOS app — that's generally the kind of use GPL's copyleft terms don't reach (no distribution of GPL-covered code, no linking into a distributed binary), but "generally" isn't a substitute for Marco actually confirming that reading holds for how he'd use it, especially given the stated preference to limit third-party dependencies in the first place. The cleaner alternative: check `mlx-community` on Hugging Face for an *already-converted* `nomic-embed-text-v1.5` MLX checkpoint first (mentioned above under "Embedding") — if one exists, `mlx-embeddings` isn't needed at all, and the GPL question disappears entirely rather than needing to be reasoned about.

## Open questions / next steps

- Confirm an `mlx-community` nomic-embed-text checkpoint exists, or budget time for the `mlx-embeddings` conversion + quantization pass.
- MLX Swift needs a BERT-style encoder (nomic-embed-text's architecture) — likely adapted from existing MLX Swift examples rather than written from scratch.
- Validate tokenizer parity (server conversion pipeline vs. `swift-transformers` WordPiece) with a golden set of (text → token ids) pairs before trusting any relevance numbers.
- Decide chunk window size empirically against a few real transcripts — 200–400 chars is a starting point, not a measured optimum.

See [server-sample/](../server-sample) and [client-sample/](../client-sample) for illustrative (not production-ready) code sketches of the chunk+embed step and the client store/query engine.
