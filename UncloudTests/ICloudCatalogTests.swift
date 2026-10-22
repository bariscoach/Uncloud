import Foundation
import os
import SQLite3
import Testing
@testable import Uncloud

/// A clock the test moves by hand.
private final class CatalogTestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ date: Date) {
        state = OSAllocatedUnfairLock(initialState: date)
    }

    var now: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private let account = "acct1234abcd5678"
private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func catalogRow(
    _ id: String,
    rank: Int = 0,
    rankCount: Int = 0,
    created: Date? = base,
    master: String? = nil,
    size: Int64? = nil,
    bytes: Int64? = nil,
    lat: Double? = nil,
    lon: Double? = nil
) -> ICloudCatalog.Row {
    ICloudCatalog.Row(
        id: id, master: master, added: base, created: created, filename: "\(id).HEIC", isVideo: false,
        size: size, bytes: bytes, latitude: lat, longitude: lon, timeZoneOffset: nil,
        rank: rank, rankCount: rankCount, seenAt: base
    )
}

private func catalogFile(in directory: URL) -> URL {
    directory.appending(path: "\(account)-PrimarySync.sqlite")
}

/// Sets `PRAGMA user_version` on a catalog file, the way another app version would have left it.
private func setUserVersion(_ version: Int, at url: URL) {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
    sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    sqlite3_close_v2(db)
}

private func userVersion(at url: URL) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_close_v2(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int64(stmt, 0))
}

@Suite("ICloudCatalog store")
struct ICloudCatalogTests {
    @Test func upsertRoundTripsThousandsOfRows() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let clock = CatalogTestClock(base)
            let catalog = try ICloudCatalog.open(account: account, directory: directory, now: { clock.now })
            let rows = (0..<2_500).map { catalogRow("id\($0)", rank: $0, rankCount: 2_500, master: "m\($0)", size: Int64($0), bytes: Int64($0) * 2, lat: 51.5, lon: -0.1) }
            try await catalog.upsert(rows)

            let ids = rows.map(\.id)
            let read = try await catalog.rows(ids: ids)
            #expect(read.count == 2_500)
            #expect(read["id42"] == rows[42])
            #expect(read["id2499"] == rows[2_499])
            #expect(try await catalog.status().rowCount == 2_500)
        }
    }

    @Test func secondUpsertKeepsNilFieldsAndReplacesRank() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            try await catalog.upsert([catalogRow("a", rank: 3, rankCount: 10, master: "M", size: 5, lat: 51.5, lon: -0.2)])
            try await catalog.upsert([catalogRow("a", rank: 9, rankCount: 12, lat: nil, lon: nil)])

            let row = try #require(try await catalog.rows(ids: ["a"])["a"])
            #expect(row.latitude == 51.5)
            #expect(row.longitude == -0.2)
            #expect(row.master == "M")
            #expect(row.size == 5)
            #expect(row.rank == 9)
            #expect(row.rankCount == 12)
        }
    }

    @Test func rowsTakenInARangeStopAtLimitAndSayWhenThereAreMore() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            let day: TimeInterval = 86_400
            // Ten rows, one a day from `base`. Rank runs backwards, so rank order is the reverse of date order.
            let rows = (0..<10).map { catalogRow("r\($0)", rank: 9 - $0, rankCount: 10, created: base.addingTimeInterval(Double($0) * day)) }
            try await catalog.upsert(rows)

            let limited = try await catalog.rows(takenFrom: base, to: base.addingTimeInterval(9 * day), limit: 5)
            #expect(limited.rows.count == 5)
            #expect(limited.isAtLeast)
            #expect(limited.rows.map(\.id) == ["r9", "r8", "r7", "r6", "r5"])

            let all = try await catalog.rows(takenFrom: base, to: base.addingTimeInterval(4 * day), limit: 10)
            #expect(all.rows.count == 5)
            #expect(!all.isAtLeast)
            #expect(Set(all.rows.map(\.id)) == ["r0", "r1", "r2", "r3", "r4"])
        }
    }

    @Test func rankHintsAddTheShiftInLibraryCount() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            try await catalog.upsert([catalogRow("x", rank: 10, rankCount: 100), catalogRow("y", rank: 0, rankCount: 105)])
            let hints = try await catalog.rankHints(for: ["x", "y", "missing"], libraryCount: 105)
            #expect(hints == ["x": 15, "y": 0])

            let page = try await catalog.page(offset: 0, limit: 2, libraryCount: 105)
            #expect(page.map(\.id) == ["y", "x"])
        }
    }

    @Test func updateBytesOnlyTouchesExistingRows() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            try await catalog.upsert([catalogRow("a"), catalogRow("b", bytes: 7)])
            try await catalog.updateBytes(["a": 100, "b": 200, "ghost": 300])
            let sizes = try await catalog.sizes()
            #expect(sizes.sizes == ["a": 100, "b": 200])
            #expect(sizes.unsized == 0)
            #expect(try await catalog.status().rowCount == 2)
        }
    }

    @Test func removeDeletesOnlyTheGivenIDs() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            try await catalog.upsert([catalogRow("a"), catalogRow("b"), catalogRow("c")])
            try await catalog.remove(ids: ["a", "c", "nope"])
            #expect(try await catalog.rows(ids: ["a", "b", "c"]).keys.sorted() == ["b"])
        }
    }

    @Test func statusReportsMetaAndTopUp() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            try await catalog.noteLibraryCount(42, unlisted: 3)
            try await catalog.noteTopUp(at: base)
            let status = try await catalog.status()
            #expect(status.libraryCount == 42)
            #expect(status.unlistedCount == 3)
            #expect(status.topUpAt == base)
            #expect(status.fullWalkStartedAt == nil && status.fullWalkEndedAt == nil)

            try await catalog.noteLibraryCount(40, unlisted: nil)
            #expect(try await catalog.status().unlistedCount == nil)
        }
    }

    // MARK: Pruning

    /// Five rows seen before a walk starts, then `seenDuringWalk` rows seen by the walk.
    private func pruneScenario(
        seenDuringWalk: Int, libraryCount: Int, unlisted: Int?, directory: URL
    ) async throws -> (ICloudCatalog.PruneResult, ICloudCatalog) {
        let clock = CatalogTestClock(base)
        let catalog = try ICloudCatalog.open(account: account, directory: directory, now: { clock.now })
        try await catalog.upsert((0..<5).map { catalogRow("old\($0)") })
        clock.advance(by: 60)
        let started = clock.now
        try await catalog.beginFullWalk(at: started)
        clock.advance(by: 60)
        try await catalog.upsert((0..<seenDuringWalk).map { catalogRow("walk\($0)") })
        clock.advance(by: 60)
        let result = try await catalog.completeFullWalk(startedAt: started, libraryCount: libraryCount, unlistedCount: unlisted)
        return (result, catalog)
    }

    @Test func fullWalkPrunesWhenItSawNinetyEightPercent() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (result, catalog) = try await pruneScenario(seenDuringWalk: 98, libraryCount: 100, unlisted: nil, directory: directory)
            #expect(result == .pruned(removed: 5))
            #expect(try await catalog.status().rowCount == 98)
        }
    }

    @Test func fullWalkPrunesAgainstLibraryMinusUnlisted() async throws {
        try await withTemporaryDirectoryAsync { directory in
            // 110 − 10 unlisted = 100 expected, so 98 seen is enough.
            let (result, _) = try await pruneScenario(seenDuringWalk: 98, libraryCount: 110, unlisted: 10, directory: directory)
            #expect(result == .pruned(removed: 5))
        }
    }

    @Test func fullWalkKeepsEverythingWhenItSawLessThanNinetyEightPercent() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let (result, catalog) = try await pruneScenario(seenDuringWalk: 90, libraryCount: 100, unlisted: nil, directory: directory)
            #expect(result == .skipped(seen: 90, expected: 100))
            #expect(try await catalog.status().rowCount == 95)
            // The walk is still marked as ended, and what it saw is recorded.
            let status = try await catalog.status()
            #expect(status.fullWalkEndedAt != nil)
        }
    }

    // MARK: Trust

    @Test func trustNeedsEveryCondition() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let clock = CatalogTestClock(base)
            let catalog = try ICloudCatalog.open(account: account, directory: directory, now: { clock.now })
            try await catalog.upsert((0..<100).map { catalogRow("t\($0)") })
            try await catalog.noteLibraryCount(100, unlisted: nil)
            let started = clock.now
            try await catalog.beginFullWalk(at: started)
            _ = try await catalog.completeFullWalk(startedAt: started, libraryCount: 100, unlistedCount: nil)
            let ended = clock.now
            let maxAge: TimeInterval = 3_600

            // All conditions hold.
            #expect(try await catalog.isTrusted(libraryCount: 100, now: ended.addingTimeInterval(10), maxAge: maxAge, toppedUp: true))
            // No top-up in this session.
            #expect(try await catalog.isTrusted(libraryCount: 100, now: ended, maxAge: maxAge, toppedUp: false) == false)
            // The full walk is too old.
            #expect(try await catalog.isTrusted(libraryCount: 100, now: ended.addingTimeInterval(7_200), maxAge: maxAge, toppedUp: true) == false)
            // The row count is off the library by more than max(50, 0.5 %): 150 is at the edge, 151 is over.
            #expect(try await catalog.isTrusted(libraryCount: 150, now: ended, maxAge: maxAge, toppedUp: true))
            #expect(try await catalog.isTrusted(libraryCount: 151, now: ended, maxAge: maxAge, toppedUp: true) == false)
        }
    }

    @Test func trustToleranceIsHalfAPercentForLargeLibraries() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let clock = CatalogTestClock(base)
            let catalog = try ICloudCatalog.open(account: account, directory: directory, now: { clock.now })
            try await catalog.upsert((0..<20_000).map { catalogRow("L\($0)") })
            let started = clock.now
            try await catalog.beginFullWalk(at: started)
            _ = try await catalog.completeFullWalk(startedAt: started, libraryCount: 20_000, unlistedCount: nil)
            let now = clock.now
            // 0.5 % of 20,000 is 100.
            #expect(try await catalog.isTrusted(libraryCount: 20_100, now: now, maxAge: 3_600, toppedUp: true))
            #expect(try await catalog.isTrusted(libraryCount: 20_101, now: now, maxAge: 3_600, toppedUp: true) == false)
        }
    }

    @Test func noFullWalkMeansNotTrusted() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            #expect(try await catalog.isTrusted(libraryCount: 0, now: base, maxAge: 3_600, toppedUp: true) == false)
        }
    }

    // MARK: Versions and recovery

    @Test func rowsSurviveReopening() async throws {
        try await withTemporaryDirectoryAsync { directory in
            do {
                let catalog = try ICloudCatalog.open(account: account, directory: directory)
                try await catalog.upsert([catalogRow("kept")])
            }
            let reopened = try ICloudCatalog.open(account: account, directory: directory)
            #expect(try await reopened.rows(ids: ["kept"]).count == 1)
        }
    }

    @Test func fileWithAnotherSchemaVersionIsRebuiltEmpty() async throws {
        try await withTemporaryDirectoryAsync { directory in
            do {
                let catalog = try ICloudCatalog.open(account: account, directory: directory)
                try await catalog.upsert([catalogRow("old1"), catalogRow("old2")])
            }
            setUserVersion(7, at: catalogFile(in: directory))

            let rebuilt = try ICloudCatalog.open(account: account, directory: directory)
            #expect(try await rebuilt.status().rowCount == 0)
            try await rebuilt.upsert([catalogRow("new")])
            #expect(try await rebuilt.status().rowCount == 1)
        }
    }

    @Test func rebuiltFileIsStampedWithCurrentVersion() async throws {
        try await withTemporaryDirectoryAsync { directory in
            do { _ = try ICloudCatalog.open(account: account, directory: directory) }
            setUserVersion(7, at: catalogFile(in: directory))
            #expect(userVersion(at: catalogFile(in: directory)) == 7)

            do { _ = try ICloudCatalog.open(account: account, directory: directory) }
            #expect(userVersion(at: catalogFile(in: directory)) == Int(ICloudCatalog.schemaVersion))
        }
    }

    @Test func newFileIsStampedWithTheSchemaVersion() async throws {
        try await withTemporaryDirectoryAsync { directory in
            do { _ = try ICloudCatalog.open(account: account, directory: directory) }
            #expect(userVersion(at: catalogFile(in: directory)) == 1)
        }
    }

    @Test func garbageFileIsReplacedByAnEmptyCatalog() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let file = catalogFile(in: directory)
            try Data(repeating: 0xAB, count: 8_192).write(to: file)

            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            #expect(try await catalog.status().rowCount == 0)
            try await catalog.upsert((0..<10).map { catalogRow("g\($0)") })
            #expect(try await catalog.status().rowCount == 10)
        }
    }

    @Test func truncatedDatabaseIsRecovered() async throws {
        try await withTemporaryDirectoryAsync { directory in
            do {
                let catalog = try ICloudCatalog.open(account: account, directory: directory)
                try await catalog.upsert((0..<300).map { catalogRow("t\($0)", master: String(repeating: "x", count: 200)) })
            }
            let file = catalogFile(in: directory)
            // Keep the first page only: the header is intact, the rest is cut off.
            let handle = try FileHandle(forUpdating: file)
            try handle.truncate(atOffset: 4_096)
            try handle.close()
            // Drop the WAL so the truncated file is what gets read.
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path(percentEncoded: false) + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path(percentEncoded: false) + "-shm"))

            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            #expect(try await catalog.status().rowCount == 0)
            try await catalog.upsert([catalogRow("after")])
            #expect(try await catalog.rows(ids: ["after"]).count == 1)
        }
    }

    @Test func unsafeAccountOrZoneNamesAreRefused() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: ICloudCatalogError.invalidName("../escape")) {
                _ = try ICloudCatalog.open(account: "../escape", directory: directory)
            }
            #expect(throws: ICloudCatalogError.invalidName("")) {
                _ = try ICloudCatalog.open(account: "", directory: directory)
            }
            #expect(throws: ICloudCatalogError.invalidName("Prime/Sync")) {
                _ = try ICloudCatalog.open(account: account, zone: "Prime/Sync", directory: directory)
            }
        }
    }

    @Test func removeAllDeletesTheFolder() async throws {
        try await withTemporaryDirectoryAsync { root in
            let folder = root.appending(path: "icloud-catalog", directoryHint: .isDirectory)
            do {
                let catalog = try ICloudCatalog.open(account: account, directory: folder)
                try await catalog.upsert([catalogRow("a")])
            }
            #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
            ICloudCatalog.removeAll(directory: folder)
            #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        }
    }

    // MARK: Benchmark

    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNCLOUD_BENCH"] == "1"))
    func benchmarkUpsertAndSizes() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let catalog = try ICloudCatalog.open(account: account, directory: directory)
            let rows = (0..<100_000).map { catalogRow("b\($0)", rank: $0, rankCount: 100_000, bytes: Int64($0)) }
            let upsertStart = ContinuousClock.now
            try await catalog.upsert(rows)
            let upsertTime = upsertStart.duration(to: .now)
            #expect(upsertTime < .seconds(2), "100k upserts took \(upsertTime)")

            let sizesStart = ContinuousClock.now
            let sizes = try await catalog.sizes()
            let sizesTime = sizesStart.duration(to: .now)
            #expect(sizes.sizes.count == 100_000)
            #expect(sizesTime < .milliseconds(200), "sizes() took \(sizesTime)")
        }
    }
}
