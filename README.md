# MarcoSemanticSearch

On-device semantic search for podcast transcripts, without changing the client's SQLite storage or adding a heavyweight search stack.

## BLUF (bottom line up front)

**Recommendation:** chunk and embed each transcript once on the Mac Mini farm at transcription time (Swift + MLX), ship the embeddings alongside the transcript in the existing sync payload, and let the client embed the search query on-device (Core ML, hitting the Neural Engine) and brute-force cosine-compare it against the small set of chunk vectors already in SQLite. No server round-trip per search, no new storage engine, no vector DB.

A few things worth knowing before reading further:

- **This is built to be code Marco owns and controls, not a black box.** Every piece of the actual feature — chunking, embedding orchestration, sync, storage, ranking, the Siri-facing App Intents — is code he'd write himself. The full breakdown is in [PROPOSAL.md's ownership table](docs/PROPOSAL.md#is-this-fully-open-source-whats-not-code-marco-owns).
- **Minimal third-party dependence, by design.** The only outside pieces are infrastructure any on-device ML feature needs from somewhere — a tokenizer, the model's weights, a math/inference library — never the feature logic itself.
- **Fully open-source and free, end to end.** No commercial software, no paid API, no license fee anywhere in the pipeline. (One build-tool-only dependency carries a GPLv3 license worth a quick look — flagged explicitly, with a way to avoid it entirely — see the ownership table.)
- **No change to the client's SQLite.** Same engine, same storage model — just two new tables (chunk text + embeddings as plain BLOBs) alongside whatever's already there. No vector extension, no `sqlite-vec`, nothing to cross-compile for iOS.
- **Backward compatible by default.** The core search feature works on essentially the whole active device population with no special hardware. The Siri/"ask a question" layer is a strictly additive enhancement, gated on Apple Intelligence availability — it degrades gracefully to manual in-app search on devices/iOS versions that don't have it. Details in [PLATFORM_COMPATIBILITY.md](docs/PLATFORM_COMPATIBILITY.md).

## Feature roadmap at a glance

Beyond the core search feature, the proposal sketches six extensions that build naturally on the same mechanism — none of them require rethinking chunking, embedding, storage, or search:

1. **[Single-episode search](docs/FEATURE_ROADMAP.md#12-single-episode-and-cross-episode-on-device-search)** — "find the part where they talked about X," always available.
2. **[Cross-episode search](docs/FEATURE_ROADMAP.md#12-single-episode-and-cross-episode-on-device-search)** — across whatever's downloaded or recently finished on-device.
3. **["Show Notes" as a second index](docs/FEATURE_ROADMAP.md#3-show-notes-as-a-second-complementary-index)** — often higher-signal than the transcript, indexed through the same pipeline.
4. **[30-day searchable backlog](docs/FEATURE_ROADMAP.md#4-30-day-searchable-backlog-for-listened-episodes)** — keeps an episode searchable for a month after finishing it, even after the audio's deleted.
5. **["What was that podcast about X?" via Siri](docs/FEATURE_ROADMAP.md#5-siri--app-intents-integration--what-was-that-podcast-about-x)** — App Intents + Assistant Schemas, fully on-device, no network round-trip.
6. **[Show/host/date metadata in the index](docs/FEATURE_ROADMAP.md#6-showhostdate-metadata-in-the-index)** — so a search hit resolves to a real answer ("Show Name, hosted by X, aired on Y"), not just a timestamp.

Full detail on each in [docs/FEATURE_ROADMAP.md](docs/FEATURE_ROADMAP.md).

**Problem:** Marco's podcast app transcribes every episode once on a farm of 40 M4 Mac Minis (on-device models), then ships the transcript to clients. He wants full-text/semantic search inside episodes (and eventually across a user's downloaded library) without adding client-side complexity — no vector DB, no server round-trip per search, no swapping SQLite for something heavier.

**Proposed approach:** chunk + embed transcripts once, server-side (Swift + MLX on the farm), at transcription time. Ship quantized embeddings alongside the transcript text as part of the existing sync payload. On the client, embed the search query on-device — via Core ML, to reach the iPhone's Neural Engine for both speed and power efficiency — and brute-force cosine-compare against the (small) set of chunk vectors already sitting in SQLite as BLOBs, using the *same* underlying `nomic-embed-text` weights as the farm. No vector index, no extension, just `Accelerate`/`vDSP` doing dot products over a few hundred to a few thousand short vectors. See [docs/PROPOSAL.md](docs/PROPOSAL.md)'s "Neural Engine vs. GPU" section for why the farm and client deliberately use different runtimes on the same model.

See [docs/PROPOSAL.md](docs/PROPOSAL.md) for the full writeup, [docs/FEATURE_ROADMAP.md](docs/FEATURE_ROADMAP.md) for the six planned extensions, [docs/NOMIC_EMBED.md](docs/NOMIC_EMBED.md) for a deep dive on the chosen embedding model (comparisons, license, update cadence, Apple's own on-device alternatives, and M4 performance estimates), [docs/PLATFORM_COMPATIBILITY.md](docs/PLATFORM_COMPATIBILITY.md) for new iOS 27 opportunities and minimum-iOS-version/backward-compatibility details, [server-sample/](server-sample/) for the Mac Mini farm chunk+embed pipeline sketch (with `swift test`-runnable unit tests for the parts that don't depend on a real MLX model), and [client-sample/](client-sample/) for the iOS-side storage + query engine sketch (same, for the parts that don't depend on a real Core ML model).

**Note on the tests:** all 23 (7 server-sample, 16 client-sample) were run for real and pass — see each sample directory's own README for exactly what's covered, what still needs the real MLX/Core ML models wired up before it can be tested, and the extra flags needed to run `swift test` in a Command Line Tools-only environment (a normal Xcode install needs none of that).
