import Foundation
import Testing
@testable import Uncloud

/// The resume logic for whole-library iCloud exports, against a library given as a list of IDs in icloudpd's
/// order (rank 0 is the NEWEST item; new photos are prepended).
@Suite("ICloudResumePlanner")
struct ICloudResumePlannerTests {
    private static let account = "acct"
    private static let settings = ICloudResumeSettings(
        minimumCovered: 50, searchWindow: 20, overlap: 20, topScanSlack: 100, pageSize: 10
    )

    /// "a0" … "a{n-1}", rank 0 first.
    private static func library(_ count: Int) -> [String] {
        (0..<count).map { "a\($0)" }
    }

    private static func point(coveredThrough: Int, library: [String], lastFullWalk: Date? = Date()) -> ICloudResumePoint {
        ICloudResumePoint(
            account: account, layout: "month", libraryCount: library.count, coveredThrough: coveredThrough,
            anchor: .init(id: library[coveredThrough - 1], rank: coveredThrough - 1),
            lastFullWalkAt: lastFullWalk, updatedAt: Date()
        )
    }

    private final class Pages: @unchecked Sendable {
        let lock = NSLock()
        var offsets: [Int] = []
        let library: [String]
        init(_ library: [String]) { self.library = library }
        func fetch(_ offset: Int, _ limit: Int) -> [String] {
            lock.withLock { offsets.append(offset) }
            guard offset < library.count else { return [] }
            return Array(library[offset..<min(library.count, offset + limit)])
        }
    }

    private static func plan(
        library: [String],
        point: ICloudResumePoint?,
        known: Set<String>,
        missing: Set<String> = [],
        now: Date = Date()
    ) async throws -> (ICloudContinuationPlan, [Int]) {
        let pages = Pages(library)
        let plan = try await ICloudResumePlanner.plan(
            .init(point: point, account: account, layout: .month, now: now, libraryCount: library.count,
                  known: known, missing: missing, settings: settings),
            fetch: { offset, limit in pages.fetch(offset, limit) }
        )
        return (plan, pages.offsets)
    }

    @Test func noPointOrAnotherLayoutOrASmallPrefixWalksEverything() async throws {
        let lib = Self.library(300)
        let known = Set(lib)
        #expect(try await Self.plan(library: lib, point: nil, known: known).0 == .fullWalk(reason: nil))
        var other = Self.point(coveredThrough: 300, library: lib)
        other.layout = "flat"
        #expect(try await Self.plan(library: lib, point: other, known: known).0 == .fullWalk(reason: nil))
        #expect(try await Self.plan(library: lib, point: Self.point(coveredThrough: 40, library: lib), known: known).0
            == .fullWalk(reason: nil))
    }

    @Test func anUnchangedLibraryContinuesJustPastTheAnchorWithoutPagingEverything() async throws {
        let lib = Self.library(300)
        let known = Set(lib.prefix(200))
        let (plan, offsets) = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: lib), known: known)
        #expect(plan == .fromRank(.init(anchorID: "a199", anchorRank: 199, only: [:], newItems: 0)))
        // A window around the anchor and the top of the library, not all 30 pages.
        #expect(Set(offsets).count <= 10)
        #expect(!offsets.contains(280))
    }

    @Test func itemsPrependedSinceTheLastExportAreFetchedFirstThenTheWalkContinuesFromTheShiftedAnchor() async throws {
        let old = Self.library(300)
        let lib = ["n0", "n1", "n2", "n3", "n4"] + old
        let (plan, _) = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: old), known: Set(old.prefix(200)))
        let expectedOnly = Dictionary(uniqueKeysWithValues: (0..<5).map { ("n\($0)", $0) })
        #expect(plan == .fromRank(.init(anchorID: "a199", anchorRank: 204, only: expectedOnly, newItems: 5)))
    }

    @Test func aBackDatedInsertAmongExportedItemsIsFoundByTheTopScan() async throws {
        let old = Self.library(300)
        var lib = old
        lib.insert("old-scan", at: 60)
        let (plan, _) = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: old), known: Set(old.prefix(200)))
        #expect(plan == .fromRank(.init(anchorID: "a199", anchorRank: 200, only: ["old-scan": 60], newItems: 1)))
    }

    /// QC P1/P2 at the planner: a back-dated insert below what the top scan reaches, hidden from the anchor's
    /// shift by a deletion (or past the prepended items it's looking for), isn't in `only`. That's safe only
    /// because a `.fromRank` run always ends with the closing walk from rank 0 to the anchor (the export tests
    /// check the item is downloaded); the plan just continues from the anchor.
    @Test func changesTheTopScanCannotSeeAreLeftToTheClosingWalkNotToAFullWalk() async throws {
        let old = Self.library(400)
        var deep = old
        deep.insert("old-scan", at: 250)
        #expect(try await Self.plan(library: deep, point: Self.point(coveredThrough: 350, library: old), known: Set(old.prefix(350))).0
            == .fromRank(.init(anchorID: "a349", anchorRank: 350, only: [:], newItems: 0)))
        // P1: a deletion and a back-dated insert: the anchor hasn't moved.
        var masked = old
        masked.remove(at: 10)
        masked.insert("old-scan", at: 250)
        #expect(try await Self.plan(library: masked, point: Self.point(coveredThrough: 350, library: old), known: Set(old.prefix(350))).0
            == .fromRank(.init(anchorID: "a349", anchorRank: 349, only: [:], newItems: 0)))
        // P2: prepends, a deletion and a deep insert: the scan finds the prepends and stops.
        var prepended = masked
        prepended.insert(contentsOf: ["n0", "n1"], at: 0)
        #expect(try await Self.plan(library: prepended, point: Self.point(coveredThrough: 350, library: old), known: Set(old.prefix(350))).0
            == .fromRank(.init(anchorID: "a349", anchorRank: 351, only: ["n0": 0, "n1": 1], newItems: 2)))
    }

    @Test func aDeletionAmongExportedItemsContinuesFromTheAnchorWhereItIsNow() async throws {
        let old = Self.library(300)
        var lib = old
        lib.remove(at: 50)
        let (plan, _) = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: old), known: Set(old.prefix(200)))
        #expect(plan == .fromRank(.init(anchorID: "a199", anchorRank: 198, only: [:], newItems: 0)))
    }

    @Test func aDeletionBelowTheAnchorLeavesItWhereItIs() async throws {
        let old = Self.library(300)
        var lib = old
        lib.remove(at: 250)
        let (plan, _) = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: old), known: Set(old.prefix(200)))
        #expect(plan == .fromRank(.init(anchorID: "a199", anchorRank: 199, only: [:], newItems: 0)))
    }

    @Test func anAnchorThatIsGoneWalksEverything() async throws {
        let old = Self.library(300)
        var lib = old
        lib.remove(at: 199)
        let gone = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: old), known: Set(old.prefix(200)))
        #expect(gone.0 == .fullWalk(reason: ICloudContinuationPlan.reasonAnchorMoved))
    }

    /// QC P3 at the planner: nothing waits for a weekly sweep any more (every run that reaches the end visits
    /// every rank), so an old last full walk, or none, doesn't change the plan.
    @Test func anOldLastFullWalkDoesNotForceAFullWalk() async throws {
        let lib = Self.library(300)
        let now = Date()
        for last in [now.addingTimeInterval(-30 * 24 * 3600), nil] {
            let point = Self.point(coveredThrough: 200, library: lib, lastFullWalk: last)
            #expect(try await Self.plan(library: lib, point: point, known: Set(lib.prefix(200)), now: now).0
                == .fromRank(.init(anchorID: "a199", anchorRank: 199, only: [:], newItems: 0)))
        }
    }

    @Test func missingFilesAtTheTopAreFetchedFirstAndDeeperOnesAreLeftToTheClosingWalk() async throws {
        let old = Self.library(300)
        let lib = ["n0", "n1"] + old
        var known = Set(old.prefix(200))
        known.remove("a3")
        known.remove("a120")
        let (plan, _) = try await Self.plan(library: lib, point: Self.point(coveredThrough: 200, library: old), known: known,
                                            missing: ["a3", "a120"])
        #expect(plan == .fromRank(.init(anchorID: "a199", anchorRank: 201, only: ["n0": 0, "n1": 1, "a3": 5], newItems: 2)))
    }

    // MARK: - Coverage

    @Test func coverageFollowsFinishedItemsAndFreezesAtTheFirstFailure() {
        var coverage = ICloudCoverage(libraryCount: 1000, base: .init(id: "a199", rank: 199))
        coverage.finished(asset: "a200", rank: 200)
        coverage.finished(asset: "a205", rank: 205)
        coverage.failed()
        coverage.finished(asset: "a206", rank: 206)
        coverage.reachedEnd(anchor: .init(id: "a999", rank: 999), libraryCount: 1000)
        let point = coverage.point(account: "x", layout: .month, previous: nil, visitedEverything: nil, now: Date())
        #expect(point?.coveredThrough == 206)
        #expect(point?.anchor == .init(id: "a205", rank: 205))
        #expect(point?.lastFullWalkAt == nil)
    }

    @Test func aWalkThatReachesTheEndMovesTheAnchorToTheLastItem() throws {
        var coverage = ICloudCoverage(libraryCount: 10, base: nil)
        coverage.finished(asset: "a3", rank: 3)
        coverage.reachedEnd(anchor: .init(id: "a9", rank: 9), libraryCount: 10)
        let started = Date().addingTimeInterval(-600)
        let point = try #require(coverage.point(account: "x", layout: .flat, previous: nil, visitedEverything: started, now: Date()))
        #expect(point.coveredThrough == 10)
        #expect(point.anchor == .init(id: "a9", rank: 9))
        #expect(point.layout == "flat")
        #expect(point.lastFullWalkAt == started)
    }

    @Test func aMissingOrInvalidatedResumePointReadsAsNoPoint() throws {
        try withTemporaryDirectory { folder in
            #expect(ICloudResumePoint.load(in: folder) == nil)
            try Self.point(coveredThrough: 60, library: Self.library(100)).save(in: folder)
            #expect(ICloudResumePoint.load(in: folder) != nil)
            try ExportManifest.invalidateResumePoint(in: folder)
            #expect(ICloudResumePoint.load(in: folder) == nil)
            try Data("{}".utf8).write(to: ICloudResumePoint.url(in: folder))
            #expect(ICloudResumePoint.load(in: folder) == nil)
        }
    }

    @Test func theResumePointRoundTripsThroughTheDestination() throws {
        try withTemporaryDirectory { folder in
            let point = Self.point(coveredThrough: 60, library: Self.library(100))
            try point.save(in: folder)
            let loaded = try #require(ICloudResumePoint.load(in: folder))
            #expect(loaded.anchor == point.anchor)
            #expect(loaded.coveredThrough == 60)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: ".photo-export/resume.json").path(percentEncoded: false)))
        }
    }

    @Test func theUnlistedCountIsOptionalAndRoundTrips() throws {
        try withTemporaryDirectory { folder in
            // A point saved before the count was kept has no field, and reads with none.
            try Self.point(coveredThrough: 60, library: Self.library(100)).save(in: folder)
            #expect(ICloudResumePoint.load(in: folder)?.unlistedCount == nil)

            var point = Self.point(coveredThrough: 60, library: Self.library(100))
            point.unlistedCount = 298
            try point.save(in: folder)
            #expect(ICloudResumePoint.load(in: folder)?.unlistedCount == 298)
        }
    }

    @Test func coverageCarriesTheUnlistedCountIntoThePoint() throws {
        var coverage = ICloudCoverage(libraryCount: 1000, base: nil)
        coverage.finished(asset: "a9", rank: 9)
        let kept = try #require(coverage.point(account: "x", layout: .month, previous: nil, visitedEverything: nil, unlistedCount: 298, now: Date()))
        #expect(kept.unlistedCount == 298)
        let unset = try #require(coverage.point(account: "x", layout: .month, previous: nil, visitedEverything: nil, now: Date()))
        #expect(unset.unlistedCount == nil)
    }

    @Test func itemsCountOnlyInTheLayoutTheyWereSavedIn() {
        let records = [
            "icloud-id:A": ["2024/07/IMG_1.JPG", "2024/07/IMG_1.MOV"],
            "icloud-id:B": ["IMG_2.JPG"],
            "icloud:2024/08/IMG_3.JPG": ["2024/08/IMG_3.JPG"],
            "icloud:Trip/IMG_4.JPG": ["Trip/IMG_4.JPG"],
        ]
        #expect(ICloudItemCount.count(records: records, layout: .month).total == 2)
        #expect(ICloudItemCount.count(records: records, layout: .flat).total == 1)
        #expect(ICloudItemCount.count(records: records).total == 4)
        #expect(ICloudItemCount.itemsByLayout(records: records) == [.month: 2, .flat: 1, .album: 1])
        #expect(!ICloudDownloadPaths.isItem(paths: ["2024/07/IMG_1.JPG"], in: .flat))
        #expect(ICloudDownloadPaths.isItem(paths: ["IMG_1.JPG", "IMG_1.JPG.xmp"], in: .flat))
    }
}
