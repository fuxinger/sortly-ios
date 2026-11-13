import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Value that can be bound to or read from a SQLite statement.
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int: Int? { if case .integer(let v) = self { Int(v) } else { nil } }
    public var double: Double? {
        switch self {
        case .real(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }
    public var string: String? { if case .text(let v) = self { v } else { nil } }
    public var data: Data? {
        switch self {
        case .blob(let d): d
        case .text(let s): Data(s.utf8)
        default: nil
        }
    }
}

public typealias SQLRow = [String: SQLValue]

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, safe SQLite wrapper. Not thread-safe by itself – always used through the
/// `SortlyStore` actor, which serializes access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]

    init(path: String?) throws {
        let target = path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(target, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
        try execute("PRAGMA foreign_keys = ON")
        if path != nil {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        for (_, statement) in statementCache { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc) }
        statementCache[sql] = statement
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .integer(let v): rc = sqlite3_bind_int64(statement, index, v)
            case .real(let v): rc = sqlite3_bind_double(statement, index, v)
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let d):
                rc = d.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
    }

    /// Executes one or more statements without results (multi-statement allowed when no bindings).
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        if values.isEmpty && sql.contains(";") {
            let rc = sqlite3_exec(handle, sql, nil, nil, nil)
            guard rc == SQLITE_OK else { throw error(rc) }
            return
        }
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        try bind(values, to: statement)
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW { rc = sqlite3_step(statement) }
        guard rc == SQLITE_DONE else { throw error(rc) }
    }

    func query(_ sql: String, _ values: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        try bind(values, to: statement)
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var row: SQLRow = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    if let pointer = sqlite3_column_blob(statement, i), count > 0 {
                        row[name] = .blob(Data(bytes: pointer, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?["user_version"]?.int) ?? 0 }
    }

    func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }

    var changes: Int { Int(sqlite3_changes(handle)) }
}
