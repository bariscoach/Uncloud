import Foundation
import Testing
@testable import Uncloud

/// The Export New Photos from a date walk, against a fake library (newest first). No Apple account, no network.
struct ExportSinceTests {
    /// Serves pages of a fixed list, newest first, like the bridge does.
    private struct FakeLibrary: ICloudPageFetching {
        let items: [ICloudAsset]

        func count() async throws -> Int {
            items.count
        }

        func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
            guard offset < items.count else { return [] }
            return Array(items[offset..<min(items.count, offset + limit)])
        }
    }

    private static func asset(_ id: String, added: TimeInterval?, created: TimeInterval? = nil) -> ICloudAsset {
        ICloudAsset(
            id: id,
            filename: "\(id).HEIC",
            created: created.map { Date(timeIntervalSince1970: $0) },
            isVideo: false,
            thumbnailURL: nil,
            added: added.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Photos taken in a range

    @Test func itemsStopAtTheFirstAddedDateBeforeTheRange() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 300),
            Self.asset("b", added: 200),
            Self.asset("c", added: 100),
            Self.asset("d", added: 50),
        ])
        let result = try await ExportSince.iCloudItems(takenFrom: Self.date(150), to: Self.date(400), fetcher: library)
        #expect(result.items == ["a": 0, "b": 1])
        #expect(!result.isAtLeast)
    }

    @Test func itemsTakenAfterTheRangeEndAreLeftOut() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 500, created: 450),
            Self.asset("b", added: 300, created: 200),
            Self.asset("c", added: 100),
        ])
        let result = try await ExportSince.iCloudItems(takenFrom: Self.date(150), to: Self.date(400), fetcher: library)
        #expect(result.items == ["b": 1])
    }

    @Test func itemsWithoutAddedDateUseCreatedAndDoNotStopTheWalk() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 300),
            Self.asset("x", added: nil, created: 250),
            Self.asset("y", added: nil, created: 50),
            Self.asset("z", added: nil, created: nil),
            Self.asset("b", added: 120),
            Self.asset("c", added: 100),
        ])
        let result = try await ExportSince.iCloudItems(takenFrom: Self.date(150), to: Self.date(400), fetcher: library)
        #expect(result.items == ["a": 0, "x": 1])
    }

    @Test func takenDateFallsBackToAddedWhenCreatedIsNil() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 300),
            Self.asset("b", added: 200, created: nil),
        ])
        let result = try await ExportSince.iCloudItems(takenFrom: Self.date(150), to: Self.date(250), fetcher: library)
        #expect(result.items == ["b": 1])
    }

    @Test func ranksKeepCountingAcrossPages() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 500),
            Self.asset("b", added: 400),
            Self.asset("c", added: 300),
            Self.asset("d", added: 200),
            Self.asset("e", added: 100),
        ])
        let result = try await ExportSince.iCloudItems(takenFrom: Self.date(250), to: Self.date(1_000), fetcher: library, pageSize: 2)
        #expect(result.items == ["a": 0, "b": 1, "c": 2])
    }

    @Test func limitMarksTheResultAsAtLeast() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 500),
            Self.asset("b", added: 400),
            Self.asset("c", added: 300),
            Self.asset("d", added: 200),
        ])
        let capped = try await ExportSince.iCloudItems(takenFrom: Self.date(0), to: Self.date(1_000), fetcher: library, pageSize: 2, limit: 3)
        #expect(capped.items == ["a": 0, "b": 1, "c": 2])
        #expect(capped.isAtLeast)

        let exact = try await ExportSince.iCloudItems(takenFrom: Self.date(0), to: Self.date(1_000), fetcher: library, pageSize: 2, limit: 4)
        #expect(exact.items.count == 4)
        #expect(!exact.isAtLeast)
    }

    @Test func nothingInTheRangeGivesNoItems() async throws {
        let library = FakeLibrary(items: [Self.asset("a", added: 100)])
        let result = try await ExportSince.iCloudItems(takenFrom: Self.date(200), to: Self.date(300), fetcher: library)
        #expect(result.items.isEmpty)
        #expect(!result.isAtLeast)
    }

    // MARK: - Suggested date

    @Test func suggestionIsTheNewestKnownItemsAddedDate() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 300),
            Self.asset("b", added: 200, created: 100),
            Self.asset("c", added: 100),
        ])
        let suggested = try await ExportSince.iCloudSuggestedDate(known: ["b", "c"], fetcher: library)
        #expect(suggested == Self.date(200))
    }

    @Test func suggestionFallsBackToCreatedWithoutAddedDate() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 300),
            Self.asset("b", added: nil, created: 250),
        ])
        let suggested = try await ExportSince.iCloudSuggestedDate(known: ["b"], fetcher: library)
        #expect(suggested == Self.date(250))
    }

    @Test func suggestionIsNilWhenNoKnownItemIsWithinTheScanLimit() async throws {
        var items = (0..<10).map { Self.asset("u\($0)", added: TimeInterval(1_000 - $0)) }
        items.append(Self.asset("known", added: 10))
        let library = FakeLibrary(items: items)

        let beyondLimit = try await ExportSince.iCloudSuggestedDate(known: ["known"], fetcher: library, pageSize: 3, scanLimit: 4)
        #expect(beyondLimit == nil)

        let withinLimit = try await ExportSince.iCloudSuggestedDate(known: ["known"], fetcher: library, pageSize: 3, scanLimit: 11)
        #expect(withinLimit == Self.date(10))

        let noneKnown = try await ExportSince.iCloudSuggestedDate(known: [], fetcher: library)
        #expect(noneKnown == nil)
    }

    // MARK: - Newest exported photo

    private static func writeFile(_ path: String, modified: TimeInterval, in destination: URL) throws {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: modified)],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private static func writeJournal(_ lines: [String], in destination: URL) throws {
        let folder = destination.appending(path: ".photo-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lines.map { $0 + "\n" }.joined().write(to: folder.appending(path: "exported.tsv"), atomically: false, encoding: .utf8)
    }

    @Test func newestPhotoIsTheLatestModifiedFileInTheJournalTail() throws {
        try withTemporaryDirectory { destination in
            try Self.writeFile("2024/07/a.HEIC", modified: 1_700_000_000, in: destination)
            try Self.writeFile("2026/10/b.HEIC", modified: 1_750_000_000, in: destination)
            try Self.writeJournal(["icloud-id:A\t2024/07/a.HEIC", "icloud-id:B\t2026/10/b.HEIC"], in: destination)

            let newest = ExportSince.newestExportedPhoto(in: destination)
            #expect(newest == ExportSince.ExportedPhoto(fileName: "b.HEIC", taken: Self.date(1_750_000_000)))
        }
    }

    @Test func newestPhotoOnlyLooksAtTheLastRecords() throws {
        try withTemporaryDirectory { destination in
            try Self.writeFile("old.HEIC", modified: 1_800_000_000, in: destination)
            try Self.writeFile("new.HEIC", modified: 1_750_000_000, in: destination)
            try Self.writeJournal(["icloud-id:OLD\told.HEIC", "icloud-id:NEW\tnew.HEIC"], in: destination)

            let newest = ExportSince.newestExportedPhoto(in: destination, limit: 1)
            #expect(newest?.fileName == "new.HEIC")
        }
    }

    @Test func newestPhotoSkipsFilesThatAreMissing() throws {
        try withTemporaryDirectory { destination in
            try Self.writeFile("kept.HEIC", modified: 1_700_000_000, in: destination)
            try Self.writeJournal(["icloud-id:GONE\tmissing.HEIC", "icloud-id:KEPT\tkept.HEIC"], in: destination)

            #expect(ExportSince.newestExportedPhoto(in: destination)?.fileName == "kept.HEIC")
        }
    }

    @Test func newestPhotoIsNilWhenNothingCanBeRead() throws {
        try withTemporaryDirectory { destination in
            #expect(ExportSince.newestExportedPhoto(in: destination) == nil)

            try Self.writeJournal(["icloud-id:GONE\tmissing.HEIC"], in: destination)
            #expect(ExportSince.newestExportedPhoto(in: destination) == nil)
        }
    }

    // MARK: - Last export

    private static func session(
        endedAt: TimeInterval?,
        updatedAt: TimeInterval = 1_000,
        exported: Int,
        status: ExportSession.Status
    ) -> ExportSession {
        var session = ExportSession(
            trigger: .manual,
            startedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "test",
            launchID: UUID(),
            source: .iCloud,
            layout: .month,
            writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: .everything, count: 0)
        )
        session.counts.exported = exported
        session.result = ExportSession.Result(status: status)
        session.updatedAt = Date(timeIntervalSince1970: updatedAt)
        session.endedAt = endedAt.map { Date(timeIntervalSince1970: $0) }
        return session
    }

    @Test func lastExportIsTheNewestSessionThatExportedFiles() throws {
        try withTemporaryDirectory { destination in
            let store = SessionStore(destination: destination)
            try store.write(Self.session(endedAt: 3_000, exported: 0, status: .completed))
            try store.write(Self.session(endedAt: 2_000, exported: 2, status: .completed))
            try store.write(Self.session(endedAt: 2_500, exported: 5, status: .interrupted))
            try store.write(Self.session(endedAt: nil, updatedAt: 4_000, exported: 9, status: .running))

            #expect(ExportSince.lastExport(in: store) == Self.date(2_500))
        }
    }

    @Test func lastExportUsesTheUpdateTimeWithoutAnEndTime() throws {
        try withTemporaryDirectory { destination in
            let store = SessionStore(destination: destination)
            try store.write(Self.session(endedAt: nil, updatedAt: 2_600, exported: 1, status: .cancelled))

            #expect(ExportSince.lastExport(in: store) == Self.date(2_600))
        }
    }

    @Test func lastExportIsNilWithoutAnyExport() throws {
        try withTemporaryDirectory { destination in
            let store = SessionStore(destination: destination)
            #expect(ExportSince.lastExport(in: store) == nil)

            try store.write(Self.session(endedAt: 2_000, exported: 0, status: .completed))
            #expect(ExportSince.lastExport(in: store) == nil)
        }
    }
}
