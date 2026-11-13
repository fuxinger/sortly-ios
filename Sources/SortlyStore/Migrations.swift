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
    ]

    /// Optional full-text index. Created only if the SQLite build has FTS5.
    static let ftsSQL = "CREATE VIRTUAL TABLE IF NOT EXISTS text_fts USING fts5(asset_id UNINDEXED, content, tokenize = 'unicode61 remove_diacritics 2')"

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = db.userVersion
        for step in steps where step.version > current {
            try db.transaction {
                try db.execute(step.sql)
                try db.setUserVersion(step.version)
            }
        }
        // FTS is optional; absence falls back to LIKE search.
        try? db.execute(ftsSQL)
    }
}
