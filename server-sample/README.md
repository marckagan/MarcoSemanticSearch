# server-sample

Illustrative sketch of the Mac Mini farm's chunk + embed step (see [../docs/PROPOSAL.md](../docs/PROPOSAL.md)). Wrapped as a small SwiftPM package so the parts that don't depend on a real MLX model can actually be built and tested — not a template for the real farm service's project structure.

- `Sources/ServerSample/ChunkAndEmbed.swift` — chunking, embedding orchestration, payload assembly.
- `Tests/ServerSampleTests/` — `ChunkerTests.swift` (windowing/overlap logic), `EmbedderTests.swift` (the `"search_document: "` prefix correctness).

## What's tested vs. not

`Chunker.chunk` and the prefixing logic (`Embedder.prefixedForStorage`) are pure functions with no model dependency, so they're tested directly. `Embedder.embed` itself, and anything that calls it (`Embedder.embedForStorage`, `PayloadBuilder.build`), end in `fatalError("wire up to the real MLX embedding model")` until a real model is wired in — `fatalError` can't be caught, so there's nothing a test could assert about that path yet. Wire up the real MLX calls first, then extend the test suite to cover them.

## Running the tests

```bash
swift test
```

**Verification status:** these tests were written and confirmed to **compile cleanly** (`swift build --build-tests`), but could not be run end-to-end in the environment they were authored in — a sandboxed macOS setup with only Command Line Tools installed, no full Xcode, and neither XCTest nor the Swift Testing runtime library available to actually execute a test bundle. The logic was hand-traced against the actual `Chunker.chunk` algorithm to check expected outputs, but that's not a substitute for actually running them. Run `swift test` for real in a normal Xcode-equipped environment before trusting these results.
