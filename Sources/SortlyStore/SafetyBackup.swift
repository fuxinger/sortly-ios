import Foundation
import SortlyCore

/// What cannot be rebuilt from the photo library: the user's decisions (overrides, rules,
/// settings, names, trip corrections), the albums Albumist manages and the execution journal
/// (history and undo). The database itself is kept out of device backups because most of it
/// is analysis that can be recomputed; this small copy goes into the backup instead, so a
/// rebuilt database (or a restored iPhone) gets the user's decisions back.
///
/// Rows are copied as stored (raw payloads), so the copy does not depend on the shape of the
/// model types and a newer app can still read an older copy.
public struct SafetyBackup: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public struct Row: Codable, Sendable, Equatable {
        public var key: String
        public var secondary: String?
        public var number: Double?
        public var payload: Data

        public init(key: String, secondary: String? = nil, number: Double? = nil, payload: Data) {
            self.key = key
            self.secondary = secondary
            self.number = number
            self.payload = payload
        }

        // Payloads are JSON text: kept as text in the file (base64 would make it a third
        // larger and hide the repetitions the compression finds). Other bytes stay base64.
        enum CodingKeys: String, CodingKey { case key, secondary, number, json, payload }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            secondary = try c.decodeIfPresent(String.self, forKey: .secondary)
            number = try c.decodeIfPresent(Double.self, forKey: .number)
            if let text = try c.decodeIfPresent(String.self, forKey: .json) {
                payload = Data(text.utf8)
            } else {
                payload = try c.decode(Data.self, forKey: .payload)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encodeIfPresent(secondary, forKey: .secondary)
            try c.encodeIfPresent(number, forKey: .number)
            if let text = String(data: payload, encoding: .utf8) {
                try c.encode(text, forKey: .json)
            } else {
                try c.encode(payload, forKey: .payload)
            }
        }
    }

    public var formatVersion: Int
    public var createdAt: Date
    /// Database schema the rows come from.
    public var schemaVersion: Int
    public var overrides: [Row]
    public var rules: [Row]
    public var managedAlbums: [Row]
    public var plans: [Row]
    /// Settings rows except computed analysis results (`analysis.*`) and in-flight execution
    /// markers (`execution.*`).
    public var values: [Row]

    public var isEmpty: Bool { overrides.isEmpty && rules.isEmpty && managedAlbums.isEmpty && plans.isEmpty && values.isEmpty }

    /// The managed-album records in this copy (to check that it belongs to this library).
    public func managedAlbumStates() -> [ManagedAlbumState] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return managedAlbums.compactMap { try? decoder.decode(ManagedAlbumState.self, from: $0.payload) }
    }

    /// Whether the copy belongs to the library whose albums are `existing`: at least half of
    /// the albums it manages are still there. After moving to a new iPhone the identifiers can
    /// differ; then only the decisions are restored, not the album records and history (they
    /// would point at albums that do not exist and read as "deleted by you").
    public func matchesLibrary(albums existing: Set<CollectionID>) -> Bool {
        let states = managedAlbumStates()
        guard !states.isEmpty else { return true }
        let found = states.filter { existing.contains($0.albumID) }.count
        return found * 2 >= states.count
    }

    // MARK: File

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        #if canImport(Darwin)
        // Plans list photo identifiers again and again: compressed, a copy for a large library
        // stays a few megabytes in the backup.
        if let packed = try? (data as NSData).compressed(using: .lzfse) as Data { data = packed }
        #endif
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a crash while writing leaves the previous copy, never half a file.
        try data.write(to: url, options: [.atomic])
    }

    public static func read(from url: URL) throws -> SafetyBackup? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        var data = try Data(contentsOf: url)
        if data.first != UInt8(ascii: "{") {
            #if canImport(Darwin)
            data = try (data as NSData).decompressed(using: .lzfse) as Data
            #else
            throw CocoaError(.fileReadCorruptFile)
            #endif
        }
        let backup = try decoder.decode(SafetyBackup.self, from: data)
        // A copy from a newer app version is left alone rather than half understood.
        return backup.formatVersion <= formatVersion ? backup : nil
    }
}

extension SortlyStore {
    /// Whether the database holds anything a backup would restore (then it is never
    /// overwritten from a copy).
    public func hasSafetyData() throws -> Bool {
        for table in ["overrides", "rules", "managed_albums", "plans"] {
            if try db.query("SELECT 1 AS x FROM \(table) LIMIT 1").isEmpty == false { return true }
        }
        return try db.query("SELECT 1 AS x FROM settings WHERE \(Self.keptValues) LIMIT 1").isEmpty == false
    }

    /// Whether the database already knows managed albums or plans (then the album records and
    /// the history of a copy are never added to it).
    public func hasLibraryState() throws -> Bool {
        for table in ["managed_albums", "plans"] {
            if try db.query("SELECT 1 AS x FROM \(table) LIMIT 1").isEmpty == false { return true }
        }
        return false
    }

    private static let keptValues = "key NOT LIKE 'analysis.%' AND key NOT LIKE 'execution.%'"

    /// A copy of everything that cannot be recomputed.
    public func safetyBackup(now: Date = Date()) throws -> SafetyBackup {
        func rows(_ sql: String, key: String, secondary: String? = nil, number: String? = nil) throws -> [SafetyBackup.Row] {
            try db.query(sql).compactMap { r in
                guard let k = r[key]?.string, let payload = r["payload"]?.data else { return nil }
                return SafetyBackup.Row(key: k, secondary: secondary.flatMap { r[$0]?.string }, number: number.flatMap { r[$0]?.double }, payload: payload)
            }
        }
        return try db.transaction {
            SafetyBackup(
                formatVersion: SafetyBackup.formatVersion,
                createdAt: now,
                schemaVersion: db.userVersion,
                overrides: try rows("SELECT id, payload, created_at FROM overrides ORDER BY id", key: "id", number: "created_at"),
                rules: try rows("SELECT id, CAST(version AS REAL) AS version, payload, updated_at FROM rules ORDER BY id, version",
                                key: "id", number: "version"),
                managedAlbums: try rows("SELECT album_id, source_id, payload FROM managed_albums ORDER BY album_id", key: "album_id", secondary: "source_id"),
                plans: try rows("SELECT id, status, created_at, payload FROM plans ORDER BY id", key: "id", secondary: "status", number: "created_at"),
                values: try rows("SELECT key, payload FROM settings WHERE \(Self.keptValues) ORDER BY key", key: "key")
            )
        }
    }

    /// Restores a copy into a database without safety data (fresh or rebuilt), in one
    /// transaction. With `includingLibraryState` false only the decisions come back, not the
    /// managed albums and the journal (they can follow later with `restoreLibraryState`, once
    /// it is clear that the copy belongs to this library). Returns false and changes nothing
    /// if the database already holds safety data.
    @discardableResult
    public func restore(_ backup: SafetyBackup, includingLibraryState: Bool) throws -> Bool {
        guard try !hasSafetyData() else { return false }
        try db.durably {
            try db.transaction {
                for r in backup.overrides {
                    try db.execute("INSERT OR REPLACE INTO overrides (id, payload, created_at) VALUES (?, ?, ?)",
                                   [.text(r.key), .blob(r.payload), r.number.map { .real($0) } ?? .null])
                }
                for r in backup.rules {
                    try db.execute("INSERT OR REPLACE INTO rules (id, version, payload, updated_at) VALUES (?, ?, ?, NULL)",
                                   [.text(r.key), .integer(Int64(r.number ?? 1)), .blob(r.payload)])
                }
                for r in backup.values {
                    try db.execute("INSERT OR REPLACE INTO settings (key, payload) VALUES (?, ?)", [.text(r.key), .blob(r.payload)])
                }
                if includingLibraryState { try insertLibraryState(backup) }
            }
        }
        return true
    }

    /// Adds the managed albums and the journal of a copy whose decisions were restored
    /// earlier. Returns false and changes nothing if the database already has either.
    @discardableResult
    public func restoreLibraryState(_ backup: SafetyBackup) throws -> Bool {
        guard try !hasLibraryState() else { return false }
        try db.durably {
            try db.transaction { try insertLibraryState(backup) }
        }
        return true
    }

    private func insertLibraryState(_ backup: SafetyBackup) throws {
        for r in backup.managedAlbums {
            try db.execute("INSERT OR REPLACE INTO managed_albums (album_id, source_id, payload) VALUES (?, ?, ?)",
                           [.text(r.key), .text(r.secondary ?? ""), .blob(r.payload)])
        }
        for r in backup.plans {
            try db.execute("INSERT OR REPLACE INTO plans (id, status, created_at, payload) VALUES (?, ?, ?, ?)",
                           [.text(r.key), .text(r.secondary ?? "completed"), r.number.map { .real($0) } ?? .null, .blob(r.payload)])
        }
    }
}
