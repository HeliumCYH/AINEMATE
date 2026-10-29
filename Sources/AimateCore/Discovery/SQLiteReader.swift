import Foundation
import SQLite3

/// A read-only window onto a database another application owns.
///
/// Only `SELECT` and read pragmas are ever issued, and the connection is opened
/// `SQLITE_OPEN_READONLY` first. The fallback to a writable handle exists because
/// a WAL database cannot be attached read-only when its `-shm` sidecar has not
/// been created yet, and `query_only` is then set so the process cannot write even
/// by accident.
final class SQLiteReader {
    private var handle: OpaquePointer?
    private(set) var path: String?

    deinit { close() }

    /// Returns false when the database cannot be opened at all, which the callers
    /// treat as "this agent is not observable right now" rather than an error to
    /// surface in the pet.
    func open(_ path: String) -> Bool {
        if self.path == path, handle != nil { return true }
        close()

        var flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            // A WAL database whose shared-memory sidecar is missing refuses a
            // read-only attach; retry writable and immediately forbid writes.
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
                sqlite3_close_v2(handle)
                handle = nil
                return false
            }
            sqlite3_exec(handle, "PRAGMA query_only = ON;", nil, nil, nil)
        }
        // The agent writes between our polls; a short busy wait beats failing the
        // whole tick and letting the pet flicker.
        sqlite3_busy_timeout(handle, 50)
        self.path = path
        return true
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
        path = nil
    }

    /// Rows keyed by column name; a SQL NULL becomes a nil value.
    func query(_ sql: String, params: [Any?] = []) -> [[String: String?]]? {
        guard let handle else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        for (offset, parameter) in params.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case nil, is NSNull:
                sqlite3_bind_null(statement, index)
            case let value as Int:
                sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, index, value)
            case let value as Double:
                sqlite3_bind_double(statement, index, value)
            case let value as String:
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            default:
                sqlite3_bind_text(statement, index, String(describing: parameter!), -1, SQLITE_TRANSIENT)
            }
        }

        var rows: [[String: String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String?] = [:]
            let columns = sqlite3_column_count(statement)
            for column in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, column))
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
                    row[name] = nil
                    continue
                }
                if let text = sqlite3_column_text(statement, column) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = nil
                }
            }
            rows.append(row)
            if rows.count >= Self.maxRows { break }
        }
        return rows
    }

    static let maxRows = 64
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
