// QueryEngineTests.swift
//
// Exercises QueryEngine.rank's brute-force cosine ranking directly against
// hand-crafted vectors -- independent of QueryEmbedder.embed, which is
// currently a fatalError stub pending a real Core ML model. This is the
// core mechanism the whole design's search quality depends on, so it's
// worth pinning down with unambiguous cases (identical, orthogonal,
// opposite vectors) rather than only integration-testing it later.

import Testing
@testable import ClientSample

struct QueryEngineTests {
    private func makeChunk(id: String, vector: [Float16], episodeId: String = "ep1") -> StoredChunk {
        StoredChunk(chunkId: id, episodeId: episodeId, startMs: 0, text: "chunk \(id)", embedding: vector)
    }

    private func closeEnough(_ a: Float, _ b: Float, tolerance: Float = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test("an identical vector scores cosine similarity 1.0")
    func identicalVectorScoresOne() {
        let query: [Float16] = [1, 0, 0, 0]
        let chunks = [makeChunk(id: "same", vector: [1, 0, 0, 0])]

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 1)

        #expect(results.first?.chunkId == "same")
        #expect(closeEnough(results.first!.score, 1.0))
    }

    @Test("an orthogonal vector scores near zero")
    func orthogonalVectorScoresZero() {
        let query: [Float16] = [1, 0, 0, 0]
        let chunks = [makeChunk(id: "orthogonal", vector: [0, 1, 0, 0])]

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 1)

        #expect(closeEnough(results.first!.score, 0.0))
    }

    @Test("an opposite vector scores cosine similarity -1.0")
    func oppositeVectorScoresNegativeOne() {
        let query: [Float16] = [1, 0, 0, 0]
        let chunks = [makeChunk(id: "opposite", vector: [-1, 0, 0, 0])]

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 1)

        #expect(closeEnough(results.first!.score, -1.0))
    }

    @Test("higher similarity ranks before lower similarity")
    func higherSimilarityRanksFirst() {
        let query: [Float16] = [1, 1, 0]
        let chunks = [
            makeChunk(id: "far", vector: [0, 1, 1]),
            makeChunk(id: "close", vector: [1, 1, 0.1]),
        ]

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 2)

        #expect(results.map(\.chunkId) == ["close", "far"])
    }

    @Test("topK truncates the result set")
    func topKTruncates() {
        let query: [Float16] = [1, 0]
        let chunks = (0..<10).map { makeChunk(id: "c\($0)", vector: [1, 0]) }

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 3)

        #expect(results.count == 3)
    }

    @Test("an empty chunk list returns an empty result")
    func emptyChunksReturnsEmpty() {
        let results = QueryEngine.rank(queryVector: [1, 0], chunks: [], topK: 5)
        #expect(results.isEmpty)
    }

    @Test("a chunk with mismatched embedding dimension is skipped, not crashed")
    func mismatchedDimensionIsSkipped() {
        // Defends the `guard vec.count == queryVec.count` in QueryEngine.rank
        // -- a chunk embedded with a stale/wrong model dimension shouldn't
        // crash the scan, just be excluded from results.
        let query: [Float16] = [1, 0, 0]
        let chunks = [
            makeChunk(id: "wrong-dim", vector: [1, 0]),
            makeChunk(id: "right-dim", vector: [1, 0, 0]),
        ]

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 5)

        #expect(results.map(\.chunkId) == ["right-dim"])
    }

    @Test("ranked results preserve the source chunk's metadata")
    func resultPreservesChunkMetadata() {
        let query: [Float16] = [1, 0]
        let chunks = [StoredChunk(chunkId: "abc", episodeId: "ep42", startMs: 12_345,
                                   text: "some transcript text", embedding: [1, 0])]

        let results = QueryEngine.rank(queryVector: query, chunks: chunks, topK: 1)

        #expect(results.first?.episodeId == "ep42")
        #expect(results.first?.startMs == 12_345)
        #expect(results.first?.text == "some transcript text")
    }
}
