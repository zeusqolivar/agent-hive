import Foundation
import SQLite3

/// Opens a SQLite database read-only, as server.py's `open_readonly`. Antigravity's database is in WAL mode, and
/// when its `-wal` and `-shm` files are absent a plain read-only open can fail ("unable to open database file");
/// `immutable=1` still reads it. Immutable is only the fallback, because it skips locking.
enum ReadonlyDatabase {
    typealias Attempt = (_ name: String, _ flags: Int32) -> OpaquePointer?

    static func open(_ path: String, attempt: Attempt = attempt) throws -> OpaquePointer {
        if let db = attempt(path, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX) { return db }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path) + "?mode=ro&immutable=1"
        if let db = attempt(uri, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI) { return db }
        throw OpenClawReader.DatabaseError(message: "unable to open database file")
    }

    /// Opens and runs one query, since some failures only show on first use.
    static func attempt(_ name: String, _ flags: Int32) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1500)
        guard sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }
}
