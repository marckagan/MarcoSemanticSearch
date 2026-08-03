// SearchIndexStoreTests.swift
//
// Exercises the real SQLite upsert/fetch round-trip against an in-memory
// database -- no mocking of SQLite itself, just an isolated :memory: DB per
// test. Uses a minimal schema matching Schema.sql's transcript_chunks and
// chunk_sync_state tables; the FTS5 virtual table is omitted since these
// tests don't exercise keyword search, only the chunk/embedding round-trip.
//
// Swift Testing creates a fresh instance of this suite per @Test, so init()
// stands in for XCTest's setUp and deinit for tearDown -- each test gets its
// own isolated in-memory database.

import Testing
import Foundation
import SQLite3
@testable import ClientSample

final class SearchIndexStoreTests {
    private let db: OpaquePointer
    private let store: SearchIndexStore

    init() throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(":memory:", &handle) == SQLITE_OK)
        db = handle!

        let schema = """
            CREATE TABLE transcript_chunks (
                chunk_id      TEXT PRIMARY KEY,
                episode_id    TEXT NOT NULL,
                start_ms      INTEGER,
                end_ms        INTEGER,
                text          TEXT NOT NULL,
                embedding     BLOB NOT NULL,
                content_hash  TEXT NOT NULL,
                updated_at    TEXT NOT NULL
            );
            CREATE TABLE chunk_sync_state (
                episode_id  TEXT PRIMARY KEY,
                cursor      TEXT NOT NULL
            );
            """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        store = SearchIndexStore(db: db)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Builds a SyncedChunk the same way it'd actually arrive -- decoded
    /// from sync-payload JSON -- rather than assuming a memberwise
    /// initializer, since that's the real code path this type exists for.
    private func makeSyncedChunk(
        id: String, text: String = "hello", startMs: Int = 0, endMs: Int = 1000,
        vector: [Float16] = [1, 2, 3], contentHash: String = "hash",
        updatedAt: String = "2026-01-01T00:00:00Z"
    ) throws -> SyncedChunk {
        let embeddingData = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        let json: [String: Any] = [
            "chunk_id": id, "start_ms": startMs, "end_ms": endMs, "text": text,
            "embedding": embeddingData.base64EncodedString(),
            "content_hash": contentHash, "updated_at": updatedAt,
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SyncedChunk.self, from: jsonData)
    }

    @Test("upsert then fetch round-trips the embedding exactly")
    func upsertThenFetchRoundTrips() throws {
        let vector: [Float16] = [1.5, -2.25, 0.0, 3.75]
        let chunk = try makeSyncedChunk(id: "ep1-0000", vector: vector)

        try store.upsert(episodeId: "ep1", chunks: [chunk], newCursor: "cursor-1")
        let fetched = try store.fetchChunks(episodeIds: ["ep1"])

        #expect(fetched.count == 1)
        #expect(fetched.first?.chunkId == "ep1-0000")
        #expect(fetched.first?.episodeId == "ep1")
        #expect(fetched.first?.embedding == vector)
    }

    @Test("upserting the same chunk_id updates it in place rather than duplicating")
    func upsertUpdatesOnConflict() throws {
        let original = try makeSyncedChunk(id: "ep1-0000", text: "original text")
        try store.upsert(episodeId: "ep1", chunks: [original], newCursor: "cursor-1")

        let updated = try makeSyncedChunk(id: "ep1-0000", text: "updated text")
        try store.upsert(episodeId: "ep1", chunks: [updated], newCursor: "cursor-2")

        let fetched = try store.fetchChunks(episodeIds: ["ep1"])
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "updated text")
    }

    @Test("fetchChunks filters to only the requested episode")
    func fetchFiltersByEpisode() throws {
        let ep1Chunk = try makeSyncedChunk(id: "ep1-0000")
        let ep2Chunk = try makeSyncedChunk(id: "ep2-0000")
        try store.upsert(episodeId: "ep1", chunks: [ep1Chunk], newCursor: "c1")
        try store.upsert(episodeId: "ep2", chunks: [ep2Chunk], newCursor: "c2")

        let fetched = try store.fetchChunks(episodeIds: ["ep1"])

        #expect(fetched.map(\.chunkId) == ["ep1-0000"])
    }

    @Test("fetchChunks spans multiple episodes for cross-episode search")
    func fetchAcrossMultipleEpisodes() throws {
        let ep1Chunk = try makeSyncedChunk(id: "ep1-0000")
        let ep2Chunk = try makeSyncedChunk(id: "ep2-0000")
        try store.upsert(episodeId: "ep1", chunks: [ep1Chunk], newCursor: "c1")
        try store.upsert(episodeId: "ep2", chunks: [ep2Chunk], newCursor: "c2")

        let fetched = try store.fetchChunks(episodeIds: ["ep1", "ep2"])

        #expect(Set(fetched.map(\.chunkId)) == Set(["ep1-0000", "ep2-0000"]))
    }

    @Test("fetchChunks with an empty episode list returns empty without querying")
    func fetchWithEmptyEpisodeIdsReturnsEmpty() throws {
        let fetched = try store.fetchChunks(episodeIds: [])
        #expect(fetched.isEmpty)
    }
}
