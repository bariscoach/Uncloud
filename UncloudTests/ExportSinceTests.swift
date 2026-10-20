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

    // MARK: - Items since a date

    @Test func itemsStopAtTheFirstOlderAddedDate() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 300),
            Self.asset("b", added: 200),
            Self.asset("c", added: 100),
            Self.asset("d", added: 50),
        ])
        let result = try await ExportSince.iCloudItems(since: Self.date(150), fetcher: library)
        #expect(result.items == ["a": 0, "b": 1])
        #expect(!result.isAtLeast)
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
        let result = try await ExportSince.iCloudItems(since: Self.date(150), fetcher: library)
        #expect(result.items == ["a": 0, "x": 1])
    }

    @Test func ranksKeepCountingAcrossPages() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 500),
            Self.asset("b", added: 400),
            Self.asset("c", added: 300),
            Self.asset("d", added: 200),
            Self.asset("e", added: 100),
        ])
        let result = try await ExportSince.iCloudItems(since: Self.date(250), fetcher: library, pageSize: 2)
        #expect(result.items == ["a": 0, "b": 1, "c": 2])
    }

    @Test func limitMarksTheResultAsAtLeast() async throws {
        let library = FakeLibrary(items: [
            Self.asset("a", added: 500),
            Self.asset("b", added: 400),
            Self.asset("c", added: 300),
            Self.asset("d", added: 200),
        ])
        let capped = try await ExportSince.iCloudItems(since: Self.date(0), fetcher: library, pageSize: 2, limit: 3)
        #expect(capped.items == ["a": 0, "b": 1, "c": 2])
        #expect(capped.isAtLeast)

        let exact = try await ExportSince.iCloudItems(since: Self.date(0), fetcher: library, pageSize: 2, limit: 4)
        #expect(exact.items.count == 4)
        #expect(!exact.isAtLeast)
    }

    @Test func nothingNewGivesNoItems() async throws {
        let library = FakeLibrary(items: [Self.asset("a", added: 100)])
        let result = try await ExportSince.iCloudItems(since: Self.date(200), fetcher: library)
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
}
