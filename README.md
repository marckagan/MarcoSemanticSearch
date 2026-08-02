# MarcoFTS

On-device semantic search for podcast transcripts, without changing the client's SQLite storage or adding a heavyweight search stack.

**Problem:** Marco's podcast app transcribes every episode once on a farm of 40 M4 Mac Minis (on-device models), then ships the transcript to clients. He wants full-text/semantic search inside episodes (and eventually across a user's downloaded library) without adding client-side complexity — no vector DB, no server round-trip per search, no swapping SQLite for something heavier.

**Proposed approach:** chunk + embed transcripts once, server-side, at transcription time. Ship quantized embeddings alongside the transcript text as part of the existing sync payload. On the client, embed the search query with a small MLX port of `nomic-embed-text` and brute-force cosine-compare against the (small) set of chunk vectors already sitting in SQLite as BLOBs — no vector index, no extension, just `Accelerate`/`vDSP` doing dot products over a few hundred to a few thousand short vectors.

See [docs/PROPOSAL.md](docs/PROPOSAL.md) for the full writeup, [docs/NOMIC_EMBED.md](docs/NOMIC_EMBED.md) for a deep dive on the chosen embedding model (comparisons, license, update cadence, Apple's own on-device alternatives, and M4 performance estimates), [server-sample/](server-sample/) for the Mac Mini farm chunk+embed pipeline sketch, and [client-sample/](client-sample/) for the iOS-side storage + query engine sketch.
