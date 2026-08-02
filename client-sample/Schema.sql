-- Schema.sql
--
-- New tables added alongside whatever existing SQLite schema already holds
-- episodes/transcripts on the client. No new SQLite extension, no vector
-- index -- embeddings are plain BLOBs, scanned brute-force at query time.

CREATE TABLE IF NOT EXISTS transcript_chunks (
    chunk_id      TEXT PRIMARY KEY,
    episode_id    TEXT NOT NULL,
    start_ms      INTEGER NOT NULL,
    end_ms        INTEGER NOT NULL,
    text          TEXT NOT NULL,
    embedding     BLOB NOT NULL,      -- fp16[768], 1536 bytes, little-endian
    content_hash  TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_chunks_episode ON transcript_chunks(episode_id);

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
