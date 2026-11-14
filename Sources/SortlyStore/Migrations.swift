import Foundation

/// Versioned schema migrations (`PRAGMA user_version`). Migrations only ever move forward;
/// every step is idempotent within its transaction. See docs/DATA_MODEL.md.
enum Migrations {
    static let steps: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE assets (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            subtypes INTEGER NOT NULL DEFAULT 0,
            creation_date REAL,
            modification_date REAL,
            latitude REAL,
            longitude REAL,
            location_accuracy REAL,
            pixel_width INTEGER NOT NULL DEFAULT 0,
            pixel_height INTEGER NOT NULL DEFAULT 0,
            duration REAL NOT NULL DEFAULT 0,
            burst_id TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            original_filename TEXT,
            uti TEXT,
            fingerprint TEXT NOT NULL,
            analysis_version INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_assets_creation ON assets(creation_date);
        CREATE INDEX idx_assets_analysis ON assets(analysis_version);
        CREATE INDEX idx_assets_location ON assets(latitude, longitude) WHERE latitude IS NOT NULL;

        CREATE TABLE collections (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            capabilities INTEGER NOT NULL,
            parent_id TEXT,
            child_ids BLOB
        );
        CREATE INDEX idx_collections_parent ON collections(parent_id);
        CREATE TABLE collection_members (
            collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            asset_id TEXT NOT NULL,
            PRIMARY KEY (collection_id, asset_id)
        ) WITHOUT ROWID;
        CREATE INDEX idx_members_asset ON collection_members(asset_id);

        CREATE TABLE place_cache (
            cell TEXT PRIMARY KEY,
            components BLOB NOT NULL,
            resolved_at REAL
        ) WITHOUT ROWID;
        CREATE TABLE asset_places (
            asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
            components BLOB NOT NULL,
            source TEXT NOT NULL,
            resolved_at REAL
        ) WITHOUT ROWID;

        CREATE TABLE analysis_results (
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            version INTEGER NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (asset_id, kind)
        ) WITHOUT ROWID;
        CREATE INDEX idx_results_kind ON analysis_results(kind, version);

        CREATE TABLE text_plain (
            asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE analysis_progress (
            stage TEXT PRIMARY KEY,
            cursor TEXT,
            version INTEGER NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0,
            updated_at REAL
        ) WITHOUT ROWID;

        CREATE TABLE overrides (id TEXT PRIMARY KEY, payload BLOB NOT NULL, created_at REAL) WITHOUT ROWID;
        CREATE TABLE rules (id TEXT NOT NULL, version INTEGER NOT NULL, payload BLOB NOT NULL, updated_at REAL, PRIMARY KEY (id, version)) WITHOUT ROWID;
        CREATE TABLE managed_albums (album_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE INDEX idx_managed_source ON managed_albums(source_id);
        CREATE TABLE plans (id TEXT PRIMARY KEY, status TEXT NOT NULL, created_at REAL, payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE INDEX idx_plans_status ON plans(status);
        CREATE TABLE settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID;
        """),
        // v2: precision of the town-level lookup, drives the overnight refinement pass.
        (2, """
        ALTER TABLE asset_places ADD COLUMN precision_m REAL;
        """),
        // v3: recognized text gets a row id so the full-text index follows it automatically
        // (triggers). Deleting a photo now also removes its text from the search index, and
        // updates no longer scan the whole index.
        (3, """
        CREATE TABLE text_plain_v3 (
            id INTEGER PRIMARY KEY,
            asset_id TEXT NOT NULL UNIQUE REFERENCES assets(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        INSERT INTO text_plain_v3 (asset_id, content) SELECT asset_id, content FROM text_plain;
        DROP TABLE text_plain;
        ALTER TABLE text_plain_v3 RENAME TO text_plain;
        DROP TABLE IF EXISTS text_fts;
        """),
    ]

    /// Optional full-text index over `text_plain` (external content), kept in sync by
    /// triggers. Created only if the SQLite build has FTS5.
    static let ftsSQL = """
        CREATE VIRTUAL TABLE text_fts USING fts5(content, content = 'text_plain', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2');
        CREATE TRIGGER text_plain_ai AFTER INSERT ON text_plain BEGIN
            INSERT INTO text_fts (rowid, content) VALUES (new.id, new.content);
        END;
        CREATE TRIGGER text_plain_ad AFTER DELETE ON text_plain BEGIN
            INSERT INTO text_fts (text_fts, rowid, content) VALUES ('delete', old.id, old.content);
        END;
        CREATE TRIGGER text_plain_au AFTER UPDATE ON text_plain BEGIN
            INSERT INTO text_fts (text_fts, rowid, content) VALUES ('delete', old.id, old.content);
            INSERT INTO text_fts (rowid, content) VALUES (new.id, new.content);
        END;
        INSERT INTO text_fts (text_fts) VALUES ('rebuild');
        """

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = db.userVersion
        for step in steps where step.version > current {
            try db.transaction {
                try db.execute(step.sql)
                try db.setUserVersion(step.version)
            }
        }
        // FTS is optional; absence falls back to LIKE search.
        let hasIndex = (try? db.query("SELECT 1 FROM sqlite_master WHERE name = 'text_fts'").isEmpty == false) ?? false
        if !hasIndex {
            do {
                try db.transaction { try db.execute(ftsSQL) }
            } catch {
                // No FTS5 in this SQLite build: search uses LIKE on text_plain.
            }
        }
    }
}
