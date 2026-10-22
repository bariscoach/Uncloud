import Foundation
import SQLite3

/// Errors from the iCloud catalog store.
enum ICloudCatalogError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    /// The account or zone name would not make a safe file name.
    case invalidName(String)
}

/// The local catalog of an iCloud library: one SQLite file per account hash and library zone, holding every item the
/// app has seen in a listing, with the fields the readers need. It is a cache. A file that is corrupt, or has another
/// schema version, is deleted and created again.
///
/// The actor serializes every call, so the connection is opened without SQLite's own mutex.
actor ICloudCatalog {
    struct Row: Equatable, Sendable {
        var id: String
        var master: String?
        var added: Date?
        var created: Date?
        var filename: String
        var isVideo: Bool
        var size: Int64?
        var bytes: Int64?
        var latitude: Double?
        var longitude: Double?
        var timeZoneOffset: Int?
        var rank: Int
        var rankCount: Int
        /// Written by `upsert` as the store's clock; read back as stored.
        var seenAt: Date
    }

    struct Status: Equatable, Sendable {
        var rowCount: Int
        var libraryCount: Int?
        var unlistedCount: Int?
        var fullWalkStartedAt: Date?
        var fullWalkEndedAt: Date?
        var topUpAt: Date?
    }

    enum PruneResult: Equatable, Sendable {
        case pruned(removed: Int)
        case skipped(seen: Int, expected: Int)
    }

    /// The schema version this build reads and writes. Any other version on disk is rebuilt.
    static let schemaVersion: Int32 = 1

    private static let upsertChunk = 1000
    private static let idChunk = 500
    /// The fraction of the library a full walk must see before it may prune.
    private static let pruneGuard = 0.98

    /// The connection. Only the actor's methods use it; deinit closes it once no other reference exists, which is why
    /// it is marked `nonisolated(unsafe)`.
    nonisolated(unsafe) private let db: OpaquePointer
    private let now: @Sendable () -> Date

    private init(db: OpaquePointer, now: @escaping @Sendable () -> Date) {
        self.db = db
        self.now = now
    }

    deinit {
        sqlite3_close_v2(db)
    }

    /// `Application Support/<bundle id>/icloud-catalog`. Sign-out deletes this folder.
    static var defaultDirectory: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appending(path: Bundle.main.bundleIdentifier ?? "com.example.Uncloud", directoryHint: .isDirectory)
            .appending(path: "icloud-catalog", directoryHint: .isDirectory)
    }

    /// Opens (or creates) the catalog for an account hash and zone, in `directory`. A file that is corrupt, unreadable,
    /// or has another schema version is deleted and created empty.
    /// - account: the pseudonymous account label (`ExportSession.accountHash(appleID:)`), never the Apple ID.
    static func open(
        account: String,
        zone: String = "PrimarySync",
        directory: URL = defaultDirectory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> ICloudCatalog {
        try requireSafeName(account)
        try requireSafeName(zone)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(account)-\(zone).sqlite")

        if let db = try? openUsable(at: url) {
            return ICloudCatalog(db: db, now: now)
        }
        // A cache with nothing to keep: start again from an empty file.
        removeFiles(at: url)
        return ICloudCatalog(db: try openUsable(at: url), now: now)
    }

    /// Deletes the whole catalog folder, such as at sign-out.
    static func removeAll(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Writes

    /// Inserts or updates rows, 1,000 per transaction. Each row is stamped with the store's clock, its rank and its
    /// library count. Fields that are nil in `rows` keep the stored value.
    func upsert(_ rows: [Row]) throws {
        guard !rows.isEmpty else { return }
        let stamp = now().timeIntervalSince1970
        let stmt = try Self.prepare(db, """
            INSERT INTO assets (id, master, added, created, filename, type, size, bytes, lat, lon, tz, rank, rankCount, seenAt)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(id) DO UPDATE SET
              master = COALESCE(excluded.master, assets.master),
              added = COALESCE(excluded.added, assets.added),
              created = COALESCE(excluded.created, assets.created),
              filename = excluded.filename,
              type = excluded.type,
              size = COALESCE(excluded.size, assets.size),
              bytes = COALESCE(excluded.bytes, assets.bytes),
              lat = COALESCE(excluded.lat, assets.lat),
              lon = COALESCE(excluded.lon, assets.lon),
              tz = COALESCE(excluded.tz, assets.tz),
              rank = excluded.rank,
              rankCount = excluded.rankCount,
              seenAt = excluded.seenAt
            """)
        defer { sqlite3_finalize(stmt) }

        for chunk in rows.chunked(Self.upsertChunk) {
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                for row in chunk {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    Self.bindText(stmt, 1, row.id)
                    Self.bindText(stmt, 2, row.master)
                    Self.bindDouble(stmt, 3, row.added?.timeIntervalSince1970)
                    Self.bindDouble(stmt, 4, row.created?.timeIntervalSince1970)
                    Self.bindText(stmt, 5, row.filename)
                    sqlite3_bind_int64(stmt, 6, row.isVideo ? 1 : 0)
                    Self.bindInt(stmt, 7, row.size)
                    Self.bindInt(stmt, 8, row.bytes)
                    Self.bindDouble(stmt, 9, row.latitude)
                    Self.bindDouble(stmt, 10, row.longitude)
                    Self.bindInt(stmt, 11, row.timeZoneOffset.map { Int64($0) })
                    sqlite3_bind_int64(stmt, 12, Int64(row.rank))
                    sqlite3_bind_int64(stmt, 13, Int64(row.rankCount))
                    sqlite3_bind_double(stmt, 14, stamp)
                    try Self.step(stmt, db)
                }
                try Self.execute(db, "COMMIT")
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// Sets `bytes` for rows that exist, from a stats page. Other fields and `seenAt` are left alone.
    func updateBytes(_ sizes: [String: Int64]) throws {
        guard !sizes.isEmpty else { return }
        let stmt = try Self.prepare(db, "UPDATE assets SET bytes = ?1 WHERE id = ?2")
        defer { sqlite3_finalize(stmt) }
        for chunk in Array(sizes).chunked(Self.upsertChunk) {
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                for (id, bytes) in chunk {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, bytes)
                    Self.bindText(stmt, 2, id)
                    try Self.step(stmt, db)
                }
                try Self.execute(db, "COMMIT")
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    func remove<C: Collection>(ids: C) throws where C.Element == String {
        guard !ids.isEmpty else { return }
        let stmt = try Self.prepare(db, "DELETE FROM assets WHERE id = ?1")
        defer { sqlite3_finalize(stmt) }
        for chunk in Array(ids).chunked(Self.upsertChunk) {
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                for id in chunk {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    Self.bindText(stmt, 1, id)
                    try Self.step(stmt, db)
                }
                try Self.execute(db, "COMMIT")
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    func noteLibraryCount(_ count: Int, unlisted: Int?) throws {
        try setMeta("libraryCount", String(count))
        try setMeta("libraryCountAt", String(now().timeIntervalSince1970))
        if let unlisted {
            try setMeta("unlistedCount", String(unlisted))
        } else {
            try deleteMeta("unlistedCount")
        }
    }

    func noteTopUp(at date: Date) throws {
        try setMeta("topUpAt", String(date.timeIntervalSince1970))
    }

    func beginFullWalk(at date: Date) throws {
        try setMeta("fullWalkStartedAt", String(date.timeIntervalSince1970))
    }

    /// Ends a full walk that started at `startedAt`. Rows not seen since then are deleted, but only when the walk saw
    /// at least 98 % of the library (`libraryCount − unlistedCount`). Either way the walk is marked as ended, and the
    /// rows seen are recorded, so `isTrusted` can see whether the row count still agrees with the library.
    func completeFullWalk(startedAt: Date, libraryCount: Int, unlistedCount: Int?) throws -> PruneResult {
        let start = startedAt.timeIntervalSince1970
        let expected = libraryCount - (unlistedCount ?? 0)
        try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            let seen = try Self.scalarInt(db, "SELECT COUNT(*) FROM assets WHERE seenAt >= ?1", bind: start)
            let result: PruneResult
            if Double(seen) >= Self.pruneGuard * Double(expected) {
                let stmt = try Self.prepare(db, "DELETE FROM assets WHERE seenAt < ?1")
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, start)
                try Self.step(stmt, db)
                result = .pruned(removed: Int(sqlite3_changes(db)))
            } else {
                result = .skipped(seen: seen, expected: expected)
            }
            try setMeta("fullWalkEndedAt", String(now().timeIntervalSince1970))
            try setMeta("fullWalkSeen", String(seen))
            try Self.execute(db, "COMMIT")
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Reads

    /// The rows for these IDs, looked up 500 at a time. IDs not in the catalog are left out.
    func rows<C: Collection>(ids: C) throws -> [String: Row] where C.Element == String {
        var found: [String: Row] = [:]
        for chunk in Array(ids).chunked(Self.idChunk) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let stmt = try Self.prepare(db, "SELECT \(Self.columns) FROM assets WHERE id IN (\(placeholders))")
            defer { sqlite3_finalize(stmt) }
            for (index, id) in chunk.enumerated() {
                Self.bindText(stmt, Int32(index + 1), id)
            }
            while try Self.stepRow(stmt, db) {
                let row = Self.readRow(stmt)
                found[row.id] = row
            }
        }
        return found
    }

    /// Rows taken between `from` and `to` (inclusive, by creation date, or added date when there is none), in rank
    /// order. `isAtLeast` is true when there were more than `limit` matches; only `limit` rows are returned.
    func rows(takenFrom from: Date, to: Date, limit: Int) throws -> (rows: [Row], isAtLeast: Bool) {
        let count = Int64(try libraryCountValue())
        let stmt = try Self.prepare(db, """
            SELECT \(Self.columns) FROM assets
            WHERE COALESCE(created, added) BETWEEN ?1 AND ?2
            ORDER BY rank + MAX(0, ?3 - rankCount), id
            LIMIT ?4
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, count)
        sqlite3_bind_int64(stmt, 4, Int64(limit) + 1)
        var rows: [Row] = []
        while try Self.stepRow(stmt, db) {
            rows.append(Self.readRow(stmt))
        }
        let isAtLeast = rows.count > limit
        return (Array(rows.prefix(limit)), isAtLeast)
    }

    /// One page of rows in rank-hint order, then by ID.
    func page(offset: Int, limit: Int, libraryCount: Int) throws -> [Row] {
        let stmt = try Self.prepare(db, """
            SELECT \(Self.columns) FROM assets
            ORDER BY rank + MAX(0, ?1 - rankCount), id
            LIMIT ?2 OFFSET ?3
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(libraryCount))
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        sqlite3_bind_int64(stmt, 3, Int64(offset))
        var rows: [Row] = []
        while try Self.stepRow(stmt, db) {
            rows.append(Self.readRow(stmt))
        }
        return rows
    }

    /// The export size (`bytes`) of every row that has one, and how many rows have none.
    func sizes() throws -> (sizes: [String: Int64], unsized: Int) {
        let stmt = try Self.prepare(db, "SELECT id, bytes FROM assets")
        defer { sqlite3_finalize(stmt) }
        var sizes: [String: Int64] = [:]
        var unsized = 0
        while try Self.stepRow(stmt, db) {
            let id = Self.text(stmt, 0) ?? ""
            if let bytes = Self.int64(stmt, 1) {
                sizes[id] = bytes
            } else {
                unsized += 1
            }
        }
        return (sizes, unsized)
    }

    /// `rank + max(0, libraryCount − rankCount)` for each ID that is in the catalog.
    func rankHints<C: Collection>(for ids: C, libraryCount: Int) throws -> [String: Int] where C.Element == String {
        var hints: [String: Int] = [:]
        for chunk in Array(ids).chunked(Self.idChunk) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let stmt = try Self.prepare(db, "SELECT id, rank, rankCount FROM assets WHERE id IN (\(placeholders))")
            defer { sqlite3_finalize(stmt) }
            for (index, id) in chunk.enumerated() {
                Self.bindText(stmt, Int32(index + 1), id)
            }
            while try Self.stepRow(stmt, db) {
                let rank = Int(sqlite3_column_int64(stmt, 1))
                let rankCount = Int(sqlite3_column_int64(stmt, 2))
                hints[Self.text(stmt, 0) ?? ""] = rank + max(0, libraryCount - rankCount)
            }
        }
        return hints
    }

    func status() throws -> Status {
        let rowCount = try Self.scalarInt(db, "SELECT COUNT(*) FROM assets")
        return Status(
            rowCount: rowCount,
            libraryCount: try metaInt("libraryCount"),
            unlistedCount: try metaInt("unlistedCount"),
            fullWalkStartedAt: try metaDate("fullWalkStartedAt"),
            fullWalkEndedAt: try metaDate("fullWalkEndedAt"),
            topUpAt: try metaDate("topUpAt")
        )
    }

    /// True when the rows can answer for the whole library: a full walk ended within `maxAge`, a top-up in this session
    /// came back `.current` (`toppedUp`), and the row count is within max(50, 0.5 %) of `libraryCount − unlistedCount`.
    func isTrusted(libraryCount: Int, now: Date, maxAge: TimeInterval, toppedUp: Bool) throws -> Bool {
        guard toppedUp else { return false }
        let status = try status()
        guard let ended = status.fullWalkEndedAt, now.timeIntervalSince(ended) <= maxAge else { return false }
        let expected = libraryCount - (status.unlistedCount ?? 0)
        let tolerance = max(50, 0.005 * Double(expected))
        return abs(Double(status.rowCount - expected)) <= tolerance
    }

    // MARK: - Opening and schema

    private static let columns = "id, master, added, created, filename, type, size, bytes, lat, lon, tz, rank, rankCount, seenAt"

    /// Opens the file and returns a connection whose schema is usable. Throws for anything that needs a rebuild.
    private static func openUsable(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        guard code == SQLITE_OK, let db = handle else {
            let error = ICloudCatalogError.sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close_v2(handle)
            throw error
        }
        do {
            _ = sqlite3_busy_timeout(db, 5_000)
            // A file that isn't a database fails here, as do damaged pages.
            let check = try strings(db, "PRAGMA quick_check")
            guard check == ["ok"] else {
                throw ICloudCatalogError.sqlite(code: SQLITE_CORRUPT, message: check.first ?? "quick_check")
            }
            let version = try scalarInt(db, "PRAGMA user_version")
            if version == 0 {
                try createSchema(db)
            } else if version != Int(schemaVersion) {
                throw ICloudCatalogError.sqlite(code: SQLITE_MISMATCH, message: "schema version \(version)")
            }
            try execute(db, "PRAGMA journal_mode = WAL")
            try execute(db, "PRAGMA synchronous = NORMAL")
            return db
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    private static func createSchema(_ db: OpaquePointer) throws {
        try inTransaction(db) {
            try execute(db, """
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID
                """)
            try execute(db, """
                CREATE TABLE IF NOT EXISTS assets(
                  id TEXT PRIMARY KEY,
                  master TEXT,
                  added REAL,
                  created REAL,
                  filename TEXT NOT NULL,
                  type INTEGER NOT NULL,
                  size INTEGER,
                  bytes INTEGER,
                  lat REAL,
                  lon REAL,
                  tz INTEGER,
                  rank INTEGER NOT NULL,
                  rankCount INTEGER NOT NULL,
                  seenAt REAL NOT NULL
                ) WITHOUT ROWID
                """)
            try execute(db, "CREATE INDEX IF NOT EXISTS assets_created ON assets(created)")
            try execute(db, "CREATE INDEX IF NOT EXISTS assets_added ON assets(added)")
            try execute(db, "CREATE INDEX IF NOT EXISTS assets_seen ON assets(seenAt)")
            try execute(db, "PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func requireSafeName(_ name: String) throws {
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard !name.isEmpty, allowed else { throw ICloudCatalogError.invalidName(name) }
    }

    private static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path(percentEncoded: false) + suffix))
        }
    }

    // MARK: - Meta

    private func setMeta(_ key: String, _ value: String) throws {
        let stmt = try Self.prepare(db, "INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(stmt) }
        Self.bindText(stmt, 1, key)
        Self.bindText(stmt, 2, value)
        try Self.step(stmt, db)
    }

    private func deleteMeta(_ key: String) throws {
        let stmt = try Self.prepare(db, "DELETE FROM meta WHERE key = ?1")
        defer { sqlite3_finalize(stmt) }
        Self.bindText(stmt, 1, key)
        try Self.step(stmt, db)
    }

    private func metaValue(_ key: String) throws -> String? {
        let stmt = try Self.prepare(db, "SELECT value FROM meta WHERE key = ?1")
        defer { sqlite3_finalize(stmt) }
        Self.bindText(stmt, 1, key)
        guard try Self.stepRow(stmt, db) else { return nil }
        return Self.text(stmt, 0)
    }

    private func metaInt(_ key: String) throws -> Int? {
        try metaValue(key).flatMap { Int($0) }
    }

    private func metaDate(_ key: String) throws -> Date? {
        try metaValue(key).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    private func libraryCountValue() throws -> Int {
        try metaInt("libraryCount") ?? 0
    }

    // MARK: - SQLite helpers

    private static func inTransaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(db, "COMMIT")
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func error(_ db: OpaquePointer) -> ICloudCatalogError {
        .sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error(db) }
        return stmt
    }

    /// Runs a statement that returns no rows.
    private static func step(_ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(db) }
    }

    /// Advances a query: true for a row, false when it is done.
    private static func stepRow(_ stmt: OpaquePointer, _ db: OpaquePointer) throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(db)
        }
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String, bind value: Double? = nil) throws -> Int {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        if let value { sqlite3_bind_double(stmt, 1, value) }
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func strings(_ db: OpaquePointer, _ sql: String) throws -> [String] {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        while try stepRow(stmt, db) {
            values.append(text(stmt, 0) ?? "")
        }
        return values
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private static func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL, let pointer = sqlite3_column_text(stmt, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    private static func double(_ stmt: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, column)
    }

    private static func int64(_ stmt: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, column)
    }

    private static func readRow(_ stmt: OpaquePointer) -> Row {
        Row(
            id: text(stmt, 0) ?? "",
            master: text(stmt, 1),
            added: double(stmt, 2).map { Date(timeIntervalSince1970: $0) },
            created: double(stmt, 3).map { Date(timeIntervalSince1970: $0) },
            filename: text(stmt, 4) ?? "",
            isVideo: sqlite3_column_int64(stmt, 5) == 1,
            size: int64(stmt, 6),
            bytes: int64(stmt, 7),
            latitude: double(stmt, 8),
            longitude: double(stmt, 9),
            timeZoneOffset: int64(stmt, 10).map { Int($0) },
            rank: Int(sqlite3_column_int64(stmt, 11)),
            rankCount: Int(sqlite3_column_int64(stmt, 12)),
            seenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
        )
    }
}

private extension Array {
    /// The elements in consecutive groups of `size`, the last one possibly shorter.
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
