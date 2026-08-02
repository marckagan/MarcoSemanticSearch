-- Schema.sql
--
-- New tables added alongside whatever existing SQLite schema already holds
-- episodes/transcripts on the client. No new SQLite extension, no vector
-- index -- embeddings are plain BLOBs, scanned brute-force at query time.

CREATE TABLE IF NOT EXISTS transcript_chunks (
    chunk_id      TEXT PRIMARY KEY,
    episode_id    TEXT NOT NULL,
    source_type   TEXT NOT NULL DEFAULT 'transcript',  -- 'transcript' | 'show_notes' | 'episode_identity'
    start_ms      INTEGER,           -- NULL for show_notes/episode_identity chunks (no timestamp)
    end_ms        INTEGER,
    text          TEXT NOT NULL,
    embedding     BLOB NOT NULL,      -- fp16[768], 1536 bytes, little-endian
    content_hash  TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_chunks_episode ON transcript_chunks(episode_id);

-- Not part of this design's storage -- assumed to already exist in the app's
-- schema for its normal library UI. Shown here only to make the join explicit:
-- transcript_chunks.episode_id -> episodes.episode_id is how a matched chunk
-- resolves to show/host/date metadata for display or a Siri response (see
-- docs/PROPOSAL.md, "Show/host/date metadata in the index"), and
-- episodes.listened_at is what the 30-day retention prune job keys off.
--
-- CREATE TABLE episodes (
--     episode_id   TEXT PRIMARY KEY,
--     show_id      TEXT NOT NULL,
--     title        TEXT NOT NULL,
--     hosts        TEXT,            -- denormalized display string, or a join to a hosts table
--     published_at TEXT NOT NULL,
--     listened_at  TEXT,            -- NULL until finished; drives the 30-day chunk-retention prune
--     is_downloaded INTEGER NOT NULL DEFAULT 0
-- );

-- Prune job (run daily): evict chunks for episodes finished >30 days ago
-- that are no longer downloaded/kept. Cheap either way -- chunks are ~1.5KB
-- each -- but keeps the table from growing unbounded over a long listening history.
-- DELETE FROM transcript_chunks
-- WHERE episode_id IN (
--     SELECT episode_id FROM episodes
--     WHERE is_downloaded = 0
--       AND listened_at IS NOT NULL
--       AND julianday('now') - julianday(listened_at) > 30
-- );

-- Optional keyword-search complement. iOS's bundled SQLite ships FTS5, so
-- this costs nothing extra to add and catches exact-term/name/jargon matches
-- that embedding similarity sometimes blurs.
CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
    text,
    content = 'transcript_chunks',
    content_rowid = 'rowid'
);

-- Sync cursor: lets the client pull only chunks changed since last sync
-- rather than re-fetching a whole episode's chunk set every time.
CREATE TABLE IF NOT EXISTS chunk_sync_state (
    episode_id  TEXT PRIMARY KEY,
    cursor      TEXT NOT NULL
);
