// QueryEngine.swift
//
// Illustrative sketch of the on-device query path: embed the search query
// via Core ML (the recommended client runtime -- see docs/PROPOSAL.md,
// "Neural Engine vs. GPU: MLX doesn't get you there", Option B), then
// brute-force cosine-compare against stored chunk vectors using
// Accelerate/vDSP. No ANN index -- at personal-corpus scale (a few hundred
// chunks per episode, up to tens of thousands across a downloaded library)
// a flat scan is single-digit milliseconds, so it isn't worth the
// dependency/complexity of an index.
//
// Farm and client deliberately use different runtimes on the SAME
// nomic-embed-text-v1.5 weights: MLX server-side (GPU, batch throughput --
// see server-sample/ChunkAndEmbed.swift), Core ML client-side (requests the
// Neural Engine, matching iOS's power+latency priorities). Both must be
// conversions of the identical checkpoint, or the two sides' vectors won't
// be comparable -- see PROPOSAL.md's tokenizer-parity note.
//
// NOT production code -- the Core ML model-loading API is illustrative; see
// docs/PROPOSAL.md "Open questions" for what needs to be wired up for real
// (HF -> Core ML conversion via coremltools, swift-transformers WordPiece
// tokenizer, a golden-set tokenizer-parity test against the farm's MLX path).
//
// Tests: see ../../Tests/ClientSampleTests. QueryEmbedder's prefixing logic
// and QueryEngine.rank's cosine-ranking are pure and tested directly against
// hand-crafted vectors; QueryEmbedder.embed() itself remains untested since
// it ends in fatalError() until a real Core ML model is wired up.

import Foundation
import Accelerate
// import CoreML

struct SearchHit {
    let chunkId: String
    let episodeId: String
    let text: String
    let startMs: Int
    let score: Float
}

// Loaded lazily on first search, not at app launch or as an eager static
// singleton -- Core ML's own guidance is to load large models on demand and
// release them under memory pressure or extended inactivity, since a reload
// benefits from Core ML's on-disk compiled-model cache (see NOMIC_EMBED.md,
// "Disk size, RAM, and delivery"). A real implementation would wrap this in
// something like an actor holding an optional MLModel?, populated on first
// `embed(_:)` call and cleared on a memory-pressure notification or an idle
// timer, rather than the always-resident `static let` pattern that would be
// tempting to reach for here.
enum QueryEmbedder {
    // private static var loadedModel: MLModel?
    //
    // private static func model() throws -> MLModel {
    //     if let loadedModel { return loadedModel }
    //     let config = MLModelConfiguration()
    //     config.computeUnits = .cpuAndNeuralEngine  // request the ANE; Core ML's
    //                                                 // scheduler still decides per-op
    //     let model = try MLModel(contentsOf: NomicEmbedTextV1_5.urlOfModelInThisBundle,
    //                              configuration: config)
    //     loadedModel = model
    //     return model
    // }
    //
    // static func unload() { loadedModel = nil }  // call on memory pressure / idle timeout

    static let queryPrefix = "search_query: "

    /// Applies nomic-embed-text's asymmetric "search_query: " prefix. Pulled
    /// out as a pure function specifically so this -- the single most
    /// important correctness requirement in this design -- can be
    /// unit-tested without a real model wired up. See
    /// Tests/ClientSampleTests/QueryEmbedderTests.swift.
    static func prefixedForQuery(_ text: String) -> String {
        queryPrefix + text
    }

    /// Embeds the search query. Must use "search_query: " -- the counterpart
    /// to the server's "search_document: " prefix used when embedding chunks
    /// for storage (see server-sample/ChunkAndEmbed.swift). Using the wrong
    /// prefix, or none, silently degrades relevance rather than erroring --
    /// this is the single most important thing to get right and verify.
    static func embed(_ query: String) throws -> [Float16] {
        // let tokens = tokenizer.encode(prefixedForQuery(query))
        // let input = try MLDictionaryFeatureProvider(dictionary: [
        //     "input_ids": MLMultiArray(tokens.ids),
        //     "attention_mask": MLMultiArray(tokens.attentionMask),
        // ])
        // let output = try model().prediction(from: input)
        // let embedding = output.featureValue(for: "embedding")!.multiArrayValue!
        // return (0..<768).map { Float16(embedding[$0].floatValue) }
        fatalError("wire up to the real Core ML embedding model for: \(prefixedForQuery(query))")
    }
}

enum QueryEngine {
    /// Searches within a single episode's chunks -- the common case ("find
    /// the part where they talked about X"). Always available since every
    /// synced episode's chunks are already local.
    static func search(query: String, episodeId: String, store: SearchIndexStore, topK: Int = 8) throws -> [SearchHit] {
        let chunks = try store.fetchChunks(episodeIds: [episodeId])
        let queryVector = try QueryEmbedder.embed(query)
        return rank(queryVector: queryVector, chunks: chunks, topK: topK)
    }

    /// Searches across a user's downloaded/kept episodes. Bounded by whatever
    /// the user already chose to store locally -- no separate storage budget
    /// to manage, it rides the existing download/retention lifecycle.
    static func searchLibrary(query: String, downloadedEpisodeIds: [String], store: SearchIndexStore, topK: Int = 20) throws -> [SearchHit] {
        let chunks = try store.fetchChunks(episodeIds: downloadedEpisodeIds)
        let queryVector = try QueryEmbedder.embed(query)
        return rank(queryVector: queryVector, chunks: chunks, topK: topK)
    }

    /// Pure cosine-ranking step, deliberately separated from the embedding
    /// call above so it can be unit-tested with hand-crafted vectors --
    /// independent of a real Core ML model being wired up. See
    /// Tests/ClientSampleTests/QueryEngineTests.swift.
    static func rank(queryVector queryVecFp16: [Float16], chunks: [StoredChunk], topK: Int) -> [SearchHit] {
        guard !chunks.isEmpty else { return [] }

        let queryVec = queryVecFp16.map { Float($0) }
        var queryNorm: Float = 0
        vDSP_svesq(queryVec, 1, &queryNorm, vDSP_Length(queryVec.count))
        queryNorm = queryNorm.squareRoot()

        var scored: [(chunk: StoredChunk, score: Float)] = []
        scored.reserveCapacity(chunks.count)

        for chunk in chunks {
            let vec = chunk.embedding.map { Float($0) }
            guard vec.count == queryVec.count else { continue }

            var dot: Float = 0
            vDSP_dotpr(queryVec, 1, vec, 1, &dot, vDSP_Length(vec.count))

            var vecNorm: Float = 0
            vDSP_svesq(vec, 1, &vecNorm, vDSP_Length(vec.count))
            vecNorm = vecNorm.squareRoot()

            let denom = queryNorm * vecNorm
            let cosine = denom > 0 ? dot / denom : 0
            scored.append((chunk, cosine))
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(topK).map {
            SearchHit(chunkId: $0.chunk.chunkId, episodeId: $0.chunk.episodeId,
                      text: $0.chunk.text, startMs: $0.chunk.startMs, score: $0.score)
        }
    }
}
