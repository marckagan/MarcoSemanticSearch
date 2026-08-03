// ChunkAndEmbed.swift
//
// Illustrative sketch of the server-side (Mac Mini farm) step that runs once
// per episode, right after transcription: chunk the transcript into
// timestamped windows, embed each chunk with an MLX port of
// nomic-embed-text-v1.5, and emit the JSON payload shipped to clients.
//
// NOT production code — the MLX model-loading API here is illustrative.
// Substitute whatever the real MLX Swift embedding checkpoint/loader exposes
// (see docs/PROPOSAL.md, "Open questions" — an mlx-community checkpoint or a
// conversion via mlx-embeddings, plus a BERT-style encoder in MLX Swift).
//
// Tests: see ../../Tests/ServerSampleTests. Chunker.chunk and Embedder's
// prefixing logic are pure and tested directly; embed()/PayloadBuilder.build
// remain untested since they end in fatalError() until a real MLX model is
// wired up (fatalError can't be caught, so there's nothing a test could
// assert about that path yet).

import Foundation
// import MLX
// import MLXNN

// MARK: - Input: transcript with word/phrase-level timestamps
// (already produced by the existing transcription step)

struct TranscriptSegment {
    let text: String
    let startMs: Int
    let endMs: Int
}

// MARK: - Output: one row per chunk, matches the `chunks` array in the sync payload

struct TranscriptChunk: Encodable {
    let chunkId: String
    let startMs: Int
    let endMs: Int
    let text: String
    let embedding: String   // base64 fp16[768]
    let contentHash: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id", startMs = "start_ms", endMs = "end_ms"
        case text, embedding
        case contentHash = "content_hash", updatedAt = "updated_at"
    }
}

// MARK: - 1. Chunking: sentence-aware windows with one-sentence overlap

enum Chunker {
    static let targetChars = 320
    static let minChars = 120

    /// Groups transcript segments into ~targetChars windows on sentence
    /// boundaries, carrying the min/max timestamp of each window's segments.
    /// Keeps the last sentence of a chunk as the first sentence of the next
    /// (one-sentence overlap) so topics near a boundary aren't split cleanly
    /// out of both neighboring chunks.
    static func chunk(_ segments: [TranscriptSegment]) -> [(text: String, startMs: Int, endMs: Int)] {
        let sentences = splitIntoSentences(segments)
        var chunks: [(text: String, startMs: Int, endMs: Int)] = []
        var current: [TranscriptSegment] = []
        var currentLen = 0

        func flush() {
            guard !current.isEmpty else { return }
            let text = current.map(\.text).joined(separator: " ")
            chunks.append((text, current.first!.startMs, current.last!.endMs))
        }

        for sentence in sentences {
            current.append(sentence)
            currentLen += sentence.text.count
            if currentLen >= targetChars {
                flush()
                // overlap: carry the last sentence into the next chunk
                current = [sentence]
                currentLen = sentence.text.count
            }
        }
        if currentLen >= minChars || chunks.isEmpty {
            flush()
        }
        return chunks
    }

    /// Splits transcript segments into sentence-level units, preserving
    /// each sentence's start/end timestamp from its constituent segments.
    private static func splitIntoSentences(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // Real implementation: use NLTokenizer (unit: .sentence) over the
        // joined text, then map sentence boundaries back to segment
        // timestamps. Sketch omitted — not the interesting part of this design.
        segments
    }
}

// MARK: - 2. Embedding: MLX nomic-embed-text, "search_document: " prefix

enum Embedder {
    // Placeholder for whatever the real MLX Swift embedding model exposes.
    // static let model = try! MLXEmbeddingModel.load(checkpoint: "mlx-community/nomic-embed-text-v1.5")

    static let documentPrefix = "search_document: "

    /// Applies nomic-embed-text's asymmetric "search_document: " prefix.
    /// Pulled out as a pure function specifically so this -- the single most
    /// important correctness requirement in this design (see PROPOSAL.md's
    /// tokenizer-parity note) -- can be unit-tested without a real model
    /// wired up. See Tests/ServerSampleTests/EmbedderTests.swift.
    static func prefixedForStorage(_ text: String) -> String {
        documentPrefix + text
    }

    /// Embeds chunk text for storage. Must use the "search_document: " prefix
    /// to match nomic-embed-text's asymmetric training — this is required for
    /// correct retrieval, not a stylistic choice. The client uses
    /// "search_query: " for the same model when embedding search queries.
    static func embedForStorage(_ text: String) throws -> [Float16] {
        try embed(prefixedForStorage(text))
    }

    private static func embed(_ text: String) throws -> [Float16] {
        // let tokens = tokenizer.encode(text)
        // let output = model(tokens)  // [768] fp32
        // return output.map { Float16($0) }
        fatalError("wire up to the real MLX embedding model")
    }
}

// MARK: - 3. Assemble chunks -> payload rows

enum PayloadBuilder {
    static func build(episodeId: String, segments: [TranscriptSegment]) throws -> [TranscriptChunk] {
        let raw = Chunker.chunk(segments)
        let now = ISO8601DateFormatter().string(from: Date())

        return try raw.enumerated().map { index, chunk in
            let embedding = try Embedder.embedForStorage(chunk.text)
            let embeddingBytes = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

            return TranscriptChunk(
                chunkId: "\(episodeId)-\(String(format: "%04d", index))",
                startMs: chunk.startMs,
                endMs: chunk.endMs,
                text: chunk.text,
                embedding: embeddingBytes.base64EncodedString(),
                contentHash: sha256Hex(chunk.text),
                updatedAt: now
            )
        }
    }

    private static func sha256Hex(_ text: String) -> String {
        // Real implementation: CryptoKit's SHA256, reusing whatever
        // content-hash convention the existing transcript indexing already uses.
        "sha256:placeholder"
    }
}

// MARK: - Example driver (one episode, one Mac Mini worker)

private struct EpisodePayload: Encodable {
    let episodeId: String
    let chunks: [TranscriptChunk]

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id", chunks
    }
}

func processEpisode(episodeId: String, segments: [TranscriptSegment]) throws -> Data {
    let chunks = try PayloadBuilder.build(episodeId: episodeId, segments: segments)
    let encoder = JSONEncoder()
    return try encoder.encode(EpisodePayload(episodeId: episodeId, chunks: chunks))
    // In practice: attach `chunks` to the existing transcript sync payload
    // rather than emitting a standalone document, and hand off to whatever
    // distribution path already ships transcripts to clients.
}
