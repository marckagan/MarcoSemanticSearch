# client-sample

Illustrative sketch of the iOS-side storage + query engine (see [../docs/PROPOSAL.md](../docs/PROPOSAL.md)). Wrapped as a small SwiftPM package so the parts that don't depend on a real Core ML model can actually be built and tested — a real app links this logic into an Xcode project targeting iOS, not a SwiftPM package targeting macOS the way this test wrapper does.

- `Sources/ClientSample/SearchIndexStore.swift` — SQLite storage layer (upsert/fetch).
- `Sources/ClientSample/QueryEngine.swift` — query embedding + brute-force cosine ranking.
- `Schema.sql` — the client-side SQLite schema (not part of the Swift target, referenced by `SearchIndexStore`'s doc comments).
- `Tests/ClientSampleTests/` — `SearchIndexStoreTests.swift` (real SQLite round-trip via an in-memory DB), `QueryEngineTests.swift` (cosine-ranking correctness against hand-crafted vectors), `QueryEmbedderTests.swift` (the `"search_query: "` prefix correctness).

## What's tested vs. not

`SearchIndexStore`'s upsert/fetch, `QueryEngine.rank`'s cosine-ranking, and `QueryEmbedder.prefixedForQuery` are all pure or fully self-contained (SQLite in-memory, hand-crafted vectors) with no model dependency, so they're tested directly and for real. `QueryEmbedder.embed` itself ends in `fatalError("wire up to the real Core ML embedding model...")` until a real model is wired in — `fatalError` can't be caught, so there's nothing a test could assert about that path yet, and neither can a true end-to-end `QueryEngine.search`/`searchLibrary` integration test until it is. The tokenizer-parity golden-set test flagged throughout the docs (PROPOSAL.md's Open Questions) also isn't written yet for the same reason — it needs both the farm's MLX tokenizer and the client's `swift-transformers` tokenizer actually wired up before there's anything to compare.

## Running the tests

```bash
swift test
```

**Verification status:** these tests were written and confirmed to **compile cleanly** (`swift build --build-tests`), but could not be run end-to-end in the environment they were authored in — a sandboxed macOS setup with only Command Line Tools installed, no full Xcode, and neither XCTest nor the Swift Testing runtime library available to actually execute a test bundle. `SearchIndexStoreTests` in particular exercises real SQLite calls and JSON decoding that were reasoned through carefully but not actually observed to pass. Run `swift test` for real in a normal Xcode-equipped environment before trusting these results.
