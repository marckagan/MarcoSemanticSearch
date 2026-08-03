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

On a normal Xcode-equipped Mac that's all it takes. In a Command Line Tools-only environment (no full Xcode.app), the linker needs to be pointed at `Testing.framework` and its runtime support library explicitly:

```bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -target -Xswiftc arm64-apple-macosx13.0 \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

**Verification status: run for real, all passing.** 16 tests across 3 suites (`SearchIndexStoreTests`, `QueryEngineTests`, `QueryEmbedderTests`), executed with the flags above in a Command Line Tools-only environment — not just compiled, actually observed to pass via Swift Testing's runner, including `SearchIndexStoreTests`' real SQLite calls and JSON decoding.
