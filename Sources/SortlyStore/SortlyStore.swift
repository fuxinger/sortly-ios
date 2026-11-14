import Foundation
import SortlyCore

/// Local persistence for Albumist. Stores metadata and analysis results only – never image
/// data or copies of originals (prompt §13). All access is serialized by this actor.
public actor SortlyStore: ChangePlanStoring {
    private let db: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var hasFullTextSearch = false

    /// - Parameter url: database file; `nil` creates an in-memory store (tests, previews).
    public init(url: URL?) throws {
        db = try SQLiteDatabase(path: url?.path)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Dates are stored as exact Double seconds since the reference date, so values
        // round-trip bit-identically (milliseconds would truncate and break equality checks
        // such as plan fingerprints and override de-duplication).
        encoder.dateEncodingStrategy = .deferredToDate
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        try Migrations.migrate(db)
        hasFullTextSearch = (try? db.query("SELECT 1 FROM sqlite_master WHERE name = 'text_fts'").isEmpty == false) ?? false
    }

    public var schemaVersion: Int { db.userVersion }

    // MARK: - Helpers

    private func json<T: Encodable>(_ value: T) throws -> SQLValue { .blob(try encoder.encode(value)) }
    private func decode<T: Decodable>(_ type: T.Type, _ value: SQLValue?) throws -> T? {
        guard let data = value?.data else { return nil }
        return try decoder.decode(type, from: data)
    }
    private static func date(_ d: Date?) -> SQLValue { d.map { .real($0.timeIntervalSince1970) } ?? .null }
    private static func text(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }

    // MARK: - Assets

    /// Inserts or updates asset metadata in one transaction. Returns ids whose metadata
    /// changed (new or modified), which drives incremental re-analysis (prompt §14.4).
    @discardableResult
    public func upsertAssets(_ assets: [AssetSnapshot]) throws -> Set<AssetID> {
        var changed = Set<AssetID>()
        try db.transaction {
            for a in assets {
                let fingerprint = Self.fingerprint(a)
                let existing = try db.query("SELECT fingerprint FROM assets WHERE id = ?", [.text(a.id.rawValue)]).first?["fingerprint"]?.string
                if existing == fingerprint { continue }
                changed.insert(a.id)
                try db.execute("""
                    INSERT INTO assets (id, kind, subtypes, creation_date, modification_date, latitude, longitude, location_accuracy,
                        pixel_width, pixel_height, duration, burst_id, is_favorite, original_filename, uti, fingerprint, analysis_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, subtypes = excluded.subtypes, creation_date = excluded.creation_date,
                        modification_date = excluded.modification_date, latitude = excluded.latitude, longitude = excluded.longitude,
                        location_accuracy = excluded.location_accuracy, pixel_width = excluded.pixel_width, pixel_height = excluded.pixel_height,
                        duration = excluded.duration, burst_id = excluded.burst_id, is_favorite = excluded.is_favorite,
                        original_filename = COALESCE(excluded.original_filename, assets.original_filename), uti = excluded.uti,
                        fingerprint = excluded.fingerprint, analysis_version = 0
                    """, [
                        .text(a.id.rawValue), .text(a.kind.rawValue), .integer(Int64(a.subtypes.rawValue)), Self.date(a.creationDate),
                        Self.date(a.modificationDate), a.location.map { .real($0.latitude) } ?? .null, a.location.map { .real($0.longitude) } ?? .null,
                        a.locationAccuracy.map { .real($0) } ?? .null, .integer(Int64(a.pixelWidth)), .integer(Int64(a.pixelHeight)),
                        .real(a.duration), Self.text(a.burstIdentifier), .integer(a.isFavorite ? 1 : 0), Self.text(a.originalFilename),
                        Self.text(a.uniformTypeIdentifier), .text(fingerprint),
                    ])
            }
        }
        return changed
    }

    static func fingerprint(_ a: AssetSnapshot) -> String {
        StableHash.hex([
            a.kind.rawValue, String(a.subtypes.rawValue), String(a.creationDate?.timeIntervalSince1970 ?? -1),
            String(a.modificationDate?.timeIntervalSince1970 ?? -1), String(a.location?.latitude ?? 999), String(a.location?.longitude ?? 999),
            String(a.pixelWidth), String(a.pixelHeight), String(a.duration),
        ].joined(separator: "|"))
    }

    /// Removes assets that no longer exist in the library (and all their analysis results).
    public func removeAssets(notIn existing: Set<AssetID>) throws -> Int {
        let all = try db.query("SELECT id FROM assets").compactMap { $0["id"]?.string }
        let stale = all.filter { !existing.contains(AssetID($0)) }
        try db.transaction {
            for id in stale { try db.execute("DELETE FROM assets WHERE id = ?", [.text(id)]) }
        }
        return stale.count
    }

    public func assetCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM assets").first?["n"]?.int ?? 0
    }

    public func allAssets() throws -> [AssetSnapshot] {
        try db.query("SELECT * FROM assets ORDER BY creation_date, id").map(Self.asset)
    }

    public func asset(_ id: AssetID) throws -> AssetSnapshot? {
        try db.query("SELECT * FROM assets WHERE id = ?", [.text(id.rawValue)]).first.map(Self.asset)
    }

    /// Assets whose analysis is older than `version` (new, changed or affected by a pipeline upgrade).
    /// Newest first. With `olderThan` (the last asset of the previous batch) the scan continues
    /// where it stopped instead of skipping every already-analyzed photo again: without it a
    /// first run over 100,000 photos spent about 18 s in this query alone.
    public func assetsNeedingAnalysis(version: Int, limit: Int, olderThan last: AssetSnapshot? = nil) throws -> [AssetSnapshot] {
        if let last, let date = last.creationDate?.timeIntervalSince1970 {
            return try db.query("""
                SELECT * FROM assets WHERE analysis_version < ?
                  AND (creation_date < ? OR (creation_date = ? AND id < ?))
                ORDER BY creation_date DESC, id DESC LIMIT ?
                """, [.integer(Int64(version)), .real(date), .real(date), .text(last.id.rawValue), .integer(Int64(limit))]).map(Self.asset)
        }
        return try db.query("SELECT * FROM assets WHERE analysis_version < ? ORDER BY creation_date DESC, id DESC LIMIT ?", [.integer(Int64(version)), .integer(Int64(limit))]).map(Self.asset)
    }

    public func countNeedingAnalysis(version: Int) throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM assets WHERE analysis_version < ?", [.integer(Int64(version))]).first?["n"]?.int ?? 0
    }

    public func markAnalyzed(_ ids: [AssetID], version: Int) throws {
        try db.transaction {
            for id in ids { try db.execute("UPDATE assets SET analysis_version = ? WHERE id = ?", [.integer(Int64(version)), .text(id.rawValue)]) }
        }
    }

    static func asset(_ r: SQLRow) -> AssetSnapshot {
        let lat = r["latitude"]?.double, lon = r["longitude"]?.double
        return AssetSnapshot(
            id: AssetID(r["id"]?.string ?? ""),
            kind: MediaKind(rawValue: r["kind"]?.string ?? "") ?? .unknown,
            subtypes: MediaSubtypes(rawValue: UInt32(r["subtypes"]?.int ?? 0)),
            creationDate: r["creation_date"]?.double.map { Date(timeIntervalSince1970: $0) },
            modificationDate: r["modification_date"]?.double.map { Date(timeIntervalSince1970: $0) },
            location: (lat != nil && lon != nil) ? GeoCoordinate(latitude: lat!, longitude: lon!) : nil,
            locationAccuracy: r["location_accuracy"]?.double,
            pixelWidth: r["pixel_width"]?.int ?? 0,
            pixelHeight: r["pixel_height"]?.int ?? 0,
            duration: r["duration"]?.double ?? 0,
            burstIdentifier: r["burst_id"]?.string,
            isFavorite: r["is_favorite"]?.int == 1,
            originalFilename: r["original_filename"]?.string,
            uniformTypeIdentifier: r["uti"]?.string
        )
    }

    // MARK: - Album inventory

    /// Replaces the stored inventory snapshot (albums, folders, memberships).
    public func saveInventory(_ inventory: CollectionInventory) throws {
        try db.transaction {
            try db.execute("DELETE FROM collection_members")
            try db.execute("DELETE FROM collections")
            for c in inventory.collections.values.sorted(by: { $0.id < $1.id }) {
                try db.execute("INSERT INTO collections (id, title, kind, capabilities, parent_id, child_ids) VALUES (?, ?, ?, ?, ?, ?)", [
                    .text(c.id.rawValue), .text(c.title), .text(c.kind.rawValue), .integer(Int64(c.capabilities.rawValue)),
                    Self.text(c.parentID?.rawValue), try json(c.childIDs),
                ])
                for a in c.assetIDs.sorted() {
                    try db.execute("INSERT INTO collection_members (collection_id, asset_id) VALUES (?, ?)", [.text(c.id.rawValue), .text(a.rawValue)])
                }
            }
        }
    }

    public func loadInventory() throws -> CollectionInventory {
        var members: [String: Set<AssetID>] = [:]
        for row in try db.query("SELECT collection_id, asset_id FROM collection_members") {
            if let c = row["collection_id"]?.string, let a = row["asset_id"]?.string { members[c, default: []].insert(AssetID(a)) }
        }
        let collections = try db.query("SELECT * FROM collections").map { r -> CollectionSnapshot in
            let id = r["id"]?.string ?? ""
            return CollectionSnapshot(
                id: CollectionID(id),
                title: r["title"]?.string ?? "",
                kind: CollectionKind(rawValue: r["kind"]?.string ?? "") ?? .restrictedAlbum,
                capabilities: CollectionCapabilities(rawValue: UInt8(r["capabilities"]?.int ?? 0)),
                parentID: r["parent_id"]?.string.map { CollectionID($0) },
                assetIDs: members[id] ?? [],
                childIDs: (try? decode([CollectionID].self, r["child_ids"])) ?? []
            )
        }
        return CollectionInventory(collections)
    }

    // MARK: - Places (geocoding cache)

    /// Cached reverse-geocoding result for a geographic cell (prompt §4.1: a resolved place
    /// is not requested again for every photo).
    public func cachedPlace(cell: GeoCell) throws -> PlaceComponents? {
        try decode(PlaceComponents.self, db.query("SELECT components FROM place_cache WHERE cell = ?", [.text(cell.description)]).first?["components"])
    }

    public func cachePlace(_ components: PlaceComponents, cell: GeoCell, resolvedAt: Date = Date()) throws {
        try db.execute("INSERT OR REPLACE INTO place_cache (cell, components, resolved_at) VALUES (?, ?, ?)", [
            .text(cell.description), try json(components), Self.date(resolvedAt),
        ])
    }

    public func placeCacheCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM place_cache").first?["n"]?.int ?? 0
    }

    public func setPlace(_ place: ResolvedPlace?, for asset: AssetID) throws {
        if let place {
            try db.execute("INSERT OR REPLACE INTO asset_places (asset_id, components, source, resolved_at, precision_m) VALUES (?, ?, ?, ?, ?)", [
                .text(asset.rawValue), try json(place.components), .text(place.source.rawValue), Self.date(place.resolvedAt),
                place.precisionMeters.map { .real($0) } ?? .null,
            ])
        } else {
            try db.execute("DELETE FROM asset_places WHERE asset_id = ?", [.text(asset.rawValue)])
        }
    }

    /// Writes many places in one transaction (geocoding results arrive in batches).
    public func setPlaces(_ places: [AssetID: ResolvedPlace]) throws {
        try db.transaction {
            for (asset, place) in places { try setPlace(place, for: asset) }
        }
    }

    public func places() throws -> [AssetID: ResolvedPlace] {
        var result: [AssetID: ResolvedPlace] = [:]
        for r in try db.query("SELECT * FROM asset_places") {
            guard let id = r["asset_id"]?.string, let c = try decode(PlaceComponents.self, r["components"]),
                  let source = PlaceSource(rawValue: r["source"]?.string ?? "") else { continue }
            result[AssetID(id)] = ResolvedPlace(
                components: c, source: source, resolvedAt: Date(timeIntervalSince1970: r["resolved_at"]?.double ?? 0),
                precisionMeters: r["precision_m"]?.double
            )
        }
        return result
    }

    // MARK: - Generic analysis results

    /// Stores a versioned analysis result per asset and kind ("vision", "ocr", "document", ...).
    public func saveResult<T: Encodable>(_ value: T, kind: String, asset: AssetID, version: Int) throws {
        try db.execute("INSERT OR REPLACE INTO analysis_results (asset_id, kind, version, payload) VALUES (?, ?, ?, ?)", [
            .text(asset.rawValue), .text(kind), .integer(Int64(version)), try json(value),
        ])
    }

    public func results<T: Decodable>(_ type: T.Type, kind: String, minimumVersion: Int = 0) throws -> [AssetID: T] {
        var out: [AssetID: T] = [:]
        for r in try db.query("SELECT asset_id, payload FROM analysis_results WHERE kind = ? AND version >= ?", [.text(kind), .integer(Int64(minimumVersion))]) {
            if let id = r["asset_id"]?.string, let v = try decode(T.self, r["payload"]) { out[AssetID(id)] = v }
        }
        return out
    }

    public func result<T: Decodable>(_ type: T.Type, kind: String, asset: AssetID) throws -> T? {
        try decode(T.self, db.query("SELECT payload FROM analysis_results WHERE kind = ? AND asset_id = ?", [.text(kind), .text(asset.rawValue)]).first?["payload"])
    }

    // MARK: - Recognized text (search)

    public func indexText(_ text: String, for asset: AssetID) throws {
        // The full-text index follows through triggers (see Migrations.ftsSQL).
        try db.execute("""
            INSERT INTO text_plain (asset_id, content) VALUES (?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET content = excluded.content
            """, [.text(asset.rawValue), .text(text)])
    }

    /// Full-text search over recognized text. Uses FTS5 when available, LIKE otherwise.
    public func searchText(_ query: String, limit: Int = 500) throws -> [AssetID] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        if hasFullTextSearch {
            let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }.joined(separator: " AND ")
            return try db.query("""
                SELECT p.asset_id FROM text_fts JOIN text_plain p ON p.id = text_fts.rowid
                WHERE text_fts MATCH ? LIMIT ?
                """, [.text(match), .integer(Int64(limit))])
                .compactMap { $0["asset_id"]?.string.map { AssetID($0) } }
        }
        let clause = terms.map { _ in "content LIKE ?" }.joined(separator: " AND ")
        return try db.query("SELECT asset_id FROM text_plain WHERE \(clause) LIMIT ?", terms.map { .text("%\($0)%") } + [.integer(Int64(limit))])
            .compactMap { $0["asset_id"]?.string.map { AssetID($0) } }
    }

    public func recognizedText(for asset: AssetID) throws -> String? {
        try db.query("SELECT content FROM text_plain WHERE asset_id = ?", [.text(asset.rawValue)]).first?["content"]?.string
    }

    // MARK: - Progress (pause / resume)

    public func setProgress(stage: String, cursor: String?, version: Int, completed: Bool) throws {
        try db.execute("INSERT OR REPLACE INTO analysis_progress (stage, cursor, version, completed, updated_at) VALUES (?, ?, ?, ?, ?)", [
            .text(stage), Self.text(cursor), .integer(Int64(version)), .integer(completed ? 1 : 0), Self.date(Date()),
        ])
    }

    public struct StageProgress: Sendable, Hashable {
        public var cursor: String?
        public var version: Int
        public var completed: Bool
    }

    public func progress(stage: String) throws -> StageProgress? {
        guard let r = try db.query("SELECT * FROM analysis_progress WHERE stage = ?", [.text(stage)]).first else { return nil }
        return StageProgress(cursor: r["cursor"]?.string, version: r["version"]?.int ?? 0, completed: r["completed"]?.int == 1)
    }

    // MARK: - Overrides, rules, managed albums, plans, settings

    public func addOverride(_ o: UserOverride) throws {
        try db.durably { try insertOverride(o) }
    }

    private func insertOverride(_ o: UserOverride) throws {
        try db.execute("INSERT OR REPLACE INTO overrides (id, payload, created_at) VALUES (?, ?, ?)", [.text(o.id.rawValue), try json(o), Self.date(o.createdAt)])
    }

    /// Stores what a reconciliation found (the user's manual changes as overrides, and the
    /// new last-known state of Albumist's albums) in one transaction: either both are saved or
    /// neither, so a manual change is never marked as seen without its override.
    public func applyReconciliation(overrides: [UserOverride], managedAlbums: [ManagedAlbumState]) throws {
        try db.durably {
            try db.transaction {
                for o in overrides { try insertOverride(o) }
                try replaceManagedAlbums(managedAlbums)
            }
        }
    }

    /// Everything that follows a finished plan, in one transaction: the plan (with its
    /// finalization time), Albumist's albums and further values (decisions, the list of plans
    /// still to finalize). A crash leaves either all of it or none.
    public func finalize(_ plan: ChangePlan, managedAlbums: [ManagedAlbumState], values: [String: any Encodable & Sendable]) throws {
        try db.durably {
            try db.transaction {
                try insertPlan(plan)
                try replaceManagedAlbums(managedAlbums)
                for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                    try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(key), try json(value)])
                }
            }
        }
    }

    public func removeOverride(_ id: SortlyID) throws {
        try db.execute("DELETE FROM overrides WHERE id = ?", [.text(id.rawValue)])
    }

    public func overrides() throws -> [UserOverride] {
        try db.query("SELECT payload FROM overrides ORDER BY created_at").compactMap { try decode(UserOverride.self, $0["payload"]) }
    }

    /// Saves a rule as a new version. Older versions stay for traceability.
    public func saveRule(_ rule: OrganizationRule) throws {
        try db.execute("INSERT OR REPLACE INTO rules (id, version, payload, updated_at) VALUES (?, ?, ?, ?)", [
            .text(rule.id.rawValue), .integer(Int64(rule.version)), try json(rule), Self.date(rule.updatedAt),
        ])
    }

    public func currentRules() throws -> [OrganizationRule] {
        try db.query("""
            SELECT r.payload FROM rules r
            JOIN (SELECT id, MAX(version) AS v FROM rules GROUP BY id) latest ON latest.id = r.id AND latest.v = r.version
            ORDER BY r.id
            """).compactMap { try decode(OrganizationRule.self, $0["payload"]) }
    }

    public func ruleHistory(_ id: SortlyID) throws -> [OrganizationRule] {
        try db.query("SELECT payload FROM rules WHERE id = ? ORDER BY version", [.text(id.rawValue)]).compactMap { try decode(OrganizationRule.self, $0["payload"]) }
    }

    public func saveManagedAlbums(_ states: [ManagedAlbumState]) throws {
        try db.durably { try db.transaction { try replaceManagedAlbums(states) } }
    }

    private func replaceManagedAlbums(_ states: [ManagedAlbumState]) throws {
        try db.execute("DELETE FROM managed_albums")
        for s in states {
            try db.execute("INSERT INTO managed_albums (album_id, source_id, payload) VALUES (?, ?, ?)", [.text(s.albumID.rawValue), .text(s.sourceID.rawValue), try json(s)])
        }
    }

    public func managedAlbums() throws -> [ManagedAlbumState] {
        try db.query("SELECT payload FROM managed_albums ORDER BY album_id").compactMap { try decode(ManagedAlbumState.self, $0["payload"]) }
    }

    /// The execution journal: on disk before the library is touched (synchronous = FULL).
    public func save(_ plan: ChangePlan) throws {
        try db.durably { try insertPlan(plan) }
    }

    /// Several plans in one transaction (an interrupted plan and the undo that replaces it).
    public func save(_ plans: [ChangePlan]) throws {
        try db.durably { try db.transaction { for plan in plans { try insertPlan(plan) } } }
    }

    private func insertPlan(_ plan: ChangePlan) throws {
        try db.execute("INSERT OR REPLACE INTO plans (id, status, created_at, payload) VALUES (?, ?, ?, ?)", [
            .text(plan.id.rawValue), .text(plan.status.rawValue), Self.date(plan.createdAt), try json(plan),
        ])
    }

    public func plan(_ id: SortlyID) throws -> ChangePlan? {
        try decode(ChangePlan.self, db.query("SELECT payload FROM plans WHERE id = ?", [.text(id.rawValue)]).first?["payload"])
    }

    /// Plans that were interrupted and must be resumed (Scenario J).
    public func unfinishedPlans() throws -> [ChangePlan] {
        try db.query("SELECT payload FROM plans WHERE status IN ('confirmed', 'running') ORDER BY created_at")
            .compactMap { try decode(ChangePlan.self, $0["payload"]) }
    }

    /// One page of finished plans, newest first.
    public func planHistory(limit: Int = 50, offset: Int = 0) throws -> [ChangePlan] {
        try db.query("SELECT payload FROM plans WHERE status IN ('completed', 'completedWithErrors') ORDER BY created_at DESC LIMIT ? OFFSET ?",
                     [.integer(Int64(limit)), .integer(Int64(offset))])
            .compactMap { try decode(ChangePlan.self, $0["payload"]) }
    }

    /// Plans that a completed undo took back, over the whole journal (not one page of it).
    public func undoneTargets() throws -> Set<SortlyID> {
        struct Header: Decodable { var reverts: SortlyID? }
        return Set(try db.query("SELECT payload FROM plans WHERE status = 'completed'")
            .compactMap { try decode(Header.self, $0["payload"])?.reverts })
    }

    public func setValue<T: Encodable>(_ value: T, forKey key: String) throws {
        try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(key), try json(value)])
    }

    public func value<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try decode(T.self, db.query("SELECT payload FROM settings WHERE key = ?", [.text(key)]).first?["payload"])
    }

    // MARK: - Reset

    /// Deletes all local analysis data. Never touches the photo library (prompt §11).
    /// User decisions (overrides, rules, managed albums, plan history) are kept unless
    /// `includingDecisions` is true.
    public func resetAnalysis(includingDecisions: Bool = false) throws {
        try db.transaction {
            for table in ["analysis_results", "asset_places", "place_cache", "analysis_progress", "text_plain"] {
                try db.execute("DELETE FROM \(table)")
            }
            try db.execute("UPDATE assets SET analysis_version = 0")
            // Results computed from the analysis (trips, places, groups, suggestions) go too,
            // otherwise the app would keep showing them until the next run finished.
            try db.execute("DELETE FROM settings WHERE key LIKE 'analysis.%'")
            if includingDecisions {
                for table in ["overrides", "rules", "managed_albums", "plans", "settings"] { try db.execute("DELETE FROM \(table)") }
            }
        }
    }
}

extension SortlyStore: PlaceCaching {}
