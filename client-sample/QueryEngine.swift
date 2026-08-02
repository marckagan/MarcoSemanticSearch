// QueryEngine.swift
//
// Illustrative sketch of the on-device query path: embed the search query
// with the same MLX nomic-embed-text model used server-side, then brute-force
// cosine-compare against stored chunk vectors using Accelerate/vDSP. No ANN
// index -- at personal-corpus scale (a few hundred chunks per episode, up to
// tens of thousands across a downloaded library) a flat scan is single-digit
// milliseconds, so it isn't worth the dependency/complexity of an index.
//
// NOT production code -- the MLX model-loading API is illustrative; see
// docs/PROPOSAL.md "Open questions" for what needs to be wired up for real
// (BERT-style encoder in MLX Swift, swift-transformers WordPiece tokenizer).

import Foundation
import Accelerate
// import MLX
// import MLXNN

struct SearchHit {
    let chunkId: String
    let episodeId: String
    let text: String
    let startMs: Int
    let score: Float
}

enum QueryEmbedder {
    // static let model = try! MLXEmbeddingModel.load(checkpoint: "mlx-community/nomic-embed-text-v1.5")

    /// Embeds the search query. Must use "search_query: " -- the counterpart
    /// to the server's "search_document: " prefix used when embedding chunks
    /// for storage (see server-sample/ChunkAndEmbed.swift). Using the wrong
    /// prefix, or none, silently degrades relevance rather than erroring --
    /// this is the single most important thing to get right and verify.
    static func embed(_ query: String) throws -> [Float16] {
        let prefixed = "search_query: " + query
        // let tokens = tokenizer.encode(prefixed)
        // let output = model(tokens)  // [768] fp32
        // return output.map { Float16($0) }
        fatalError("wire up to the real MLX embedding model")
    }
}

enum QueryEngine {
    /// Searches within a single episode's chunks -- the common case ("find
    /// the part where they talked about X"). Always available since every
    /// synced episode's chunks are already local.
    static func search(query: String, episodeId: String, store: SearchIndexStore, topK: Int = 8) throws -> [SearchHit] {
        let chunks = try store.fetchChunks(episodeIds: [episodeId])
        return try rank(query: query, chunks: chunks, topK: topK)
    }

    /// Searches across a user's downloaded/kept episodes. Bounded by whatever
    /// the user already chose to store locally -- no separate storage budget
    /// to manage, it rides the existing download/retention lifecycle.
    static func searchLibrary(query: String, downloadedEpisodeIds: [String], store: SearchIndexStore, topK: Int = 20) throws -> [SearchHit] {
        let chunks = try store.fetchChunks(episodeIds: downloadedEpisodeIds)
        return try rank(query: query, chunks: chunks, topK: topK)
    }

    private static func rank(query: String, chunks: [StoredChunk], topK: Int) throws -> [SearchHit] {
        guard !chunks.isEmpty else { return [] }

        let queryVecFp16 = try QueryEmbedder.embed(query)
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
