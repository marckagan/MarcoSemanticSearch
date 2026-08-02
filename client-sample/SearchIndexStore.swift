// SearchIndexStore.swift
//
// Illustrative sketch of the client-side storage layer: inserts chunks
// synced from the server into the existing SQLite database (see Schema.sql)
// and reads them back for querying. Uses raw sqlite3 calls to stay dependency-
// free and match "don't change the client's SQLite setup" -- swap in
// whatever wrapper (GRDB, SQLite.swift) the app already uses.
//
// NOT production code -- error handling, connection lifecycle, and batching
// are simplified for readability.

import Foundation
import SQLite3

struct SyncedChunk: Decodable {
    let chunkId: String
    let startMs: Int
    let endMs: Int
    let text: String
    let embedding: String   // base64 fp16[768], as shipped in the sync payload
    let contentHash: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id", startMs = "start_ms", endMs = "end_ms"
        case text, embedding
        case contentHash = "content_hash", updatedAt = "updated_at"
    }
}

struct StoredChunk {
    let chunkId: String
    let episodeId: String
    let startMs: Int
    let text: String
    let embedding: [Float16]   // decoded from the BLOB, ready for cosine compare
}

final class SearchIndexStore {
    private let db: OpaquePointer

    init(db: OpaquePointer) {
        self.db = db
    }

    /// Upserts chunks synced from the server for one episode. Called after
    /// pulling anything changed since the episode's stored sync cursor.
    func upsert(episodeId: String, chunks: [SyncedChunk], newCursor: String) throws {
        let insertSQL = """
            INSERT INTO transcript_chunks
                (chunk_id, episode_id, start_ms, end_ms, text, embedding, content_hash, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(chunk_id) DO UPDATE SET
                text = excluded.text,
                embedding = excluded.embedding,
                content_hash = excluded.content_hash,
                updated_at = excluded.updated_at
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        try withTransaction {
            for chunk in chunks {
                guard let embeddingData = Data(base64Encoded: chunk.embedding) else {
                    continue
                }
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, chunk.chunkId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, episodeId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(chunk.startMs))
                sqlite3_bind_int(stmt, 4, Int32(chunk.endMs))
                sqlite3_bind_text(stmt, 5, chunk.text, -1, SQLITE_TRANSIENT)
                embeddingData.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_text(stmt, 7, chunk.contentHash, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, chunk.updatedAt, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StoreError.insertFailed
                }
            }
            try setCursor(episodeId: episodeId, cursor: newCursor)
        }
    }

    /// Fetches decoded chunk vectors for a set of episodes -- one episode for
    /// intra-episode search, or the user's downloaded/kept set for
    /// cross-episode search. Bounded by what's already synced locally.
    func fetchChunks(episodeIds: [String]) throws -> [StoredChunk] {
        guard !episodeIds.isEmpty else { return [] }
        let placeholders = episodeIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT chunk_id, episode_id, start_ms, text, embedding
            FROM transcript_chunks
            WHERE episode_id IN (\(placeholders))
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (i, episodeId) in episodeIds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), episodeId, -1, SQLITE_TRANSIENT)
        }

        var results: [StoredChunk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkId = String(cString: sqlite3_column_text(stmt, 0))
            let episodeId = String(cString: sqlite3_column_text(stmt, 1))
            let startMs = Int(sqlite3_column_int(stmt, 2))
            let text = String(cString: sqlite3_column_text(stmt, 3))

            let blobPtr = sqlite3_column_blob(stmt, 4)
            let blobLen = Int(sqlite3_column_bytes(stmt, 4))
            let embedding = decodeFp16(blobPtr, count: blobLen)

            results.append(StoredChunk(chunkId: chunkId, episodeId: episodeId,
                                        startMs: startMs, text: text, embedding: embedding))
        }
        return results
    }

    private func setCursor(episodeId: String, cursor: String) throws {
        let sql = """
            INSERT INTO chunk_sync_state (episode_id, cursor) VALUES (?, ?)
            ON CONFLICT(episode_id) DO UPDATE SET cursor = excluded.cursor
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, episodeId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, cursor, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        do {
            try body()
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func decodeFp16(_ ptr: UnsafeRawPointer?, count: Int) -> [Float16] {
        guard let ptr else { return [] }
        let n = count / MemoryLayout<Float16>.size
        let buffer = ptr.bindMemory(to: Float16.self, capacity: n)
        return Array(UnsafeBufferPointer(start: buffer, count: n))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StoreError: Error {
    case prepareFailed
    case insertFailed
}
