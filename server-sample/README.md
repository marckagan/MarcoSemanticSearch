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

On a normal Xcode-equipped Mac that's all it takes. In a Command Line Tools-only environment (no full Xcode.app), the linker needs to be pointed at `Testing.framework` and its runtime support library explicitly:

```bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -target -Xswiftc arm64-apple-macosx13.0 \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

**Verification status: run for real, all passing.** 7 tests across 2 suites (`ChunkerTests`, `EmbedderTests`), executed with the flags above in a Command Line Tools-only environment — not just compiled, actually observed to pass via Swift Testing's runner.
