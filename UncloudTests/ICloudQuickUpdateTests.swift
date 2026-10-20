import Foundation
import Testing
@testable import Uncloud

/// The quick update for whole-library iCloud exports (new photos at the top only), against a library given as a
/// list of IDs in icloudpd's order (rank 0 is the NEWEST item; new photos are prepended).
@Suite("ICloudQuickUpdate")
struct ICloudQuickUpdateTests {
    private static let account = "acct"
    private static let settings = ICloudResumeSettings(overlap: 20, pageSize: 10, quickScanLimit: 200, quickMaxItems: 50)
    private static let day: TimeInterval = 24 * 60 * 60

    /// "a0" … "a{n-1}", rank 0 first.
    private static func library(_ count: Int) -> [String] {
        (0..<count).map { "a\($0)" }
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
        known: Set<String>,
        settings: ICloudResumeSettings = settings
    ) async throws -> (ICloudQuickUpdate.Plan, [Int]) {
        let pages = Pages(library)
        let plan = try await ICloudQuickUpdate.plan(
            libraryCount: library.count, known: known, settings: settings,
            fetch: { offset, limit in pages.fetch(offset, limit) }
        )
        return (plan, pages.offsets)
    }

    private static func point(lastFullWalk: Date?, account: String = account, layout: String = "month") -> ICloudResumePoint {
        ICloudResumePoint(
            account: account, layout: layout, libraryCount: 300, coveredThrough: 300,
            anchor: .init(id: "a299", rank: 299), lastFullWalkAt: lastFullWalk, updatedAt: Date()
        )
    }

    @Test func newItemsAtTheTopAreReturnedWithTheirRanksAndTheScanStopsAfterAnOverlap() async throws {
        let old = Self.library(300)
        let lib = ["n0", "n1", "n2"] + old
        let (plan, offsets) = try await Self.plan(library: lib, known: Set(old.prefix(200)))
        #expect(plan == .only(["n0": 0, "n1": 1, "n2": 2]))
        // Three pages: the 20 known items in a row end the scan at rank 23, not at the end of the library.
        #expect(offsets == [0, 10, 20])
    }

    @Test func noNewItemsIsAnEmptyPlanAfterOneOverlapsWorthOfPages() async throws {
        let lib = Self.library(300)
        let (plan, offsets) = try await Self.plan(library: lib, known: Set(lib))
        #expect(plan == .only([:]))
        #expect(offsets == [0, 10])
    }

    @Test func aSmallLibraryWithEverythingNewReachesTheEndAndDownloadsAll() async throws {
        let lib = Self.library(5)
        let (plan, offsets) = try await Self.plan(library: lib, known: [])
        #expect(plan == .only(Dictionary(uniqueKeysWithValues: (0..<5).map { ("a\($0)", $0) })))
        #expect(offsets == [0])
    }

    @Test func aLibraryThatEndsBeforeTheOverlapIsDoneWithWhatWasNew() async throws {
        let lib = ["n0"] + Self.library(4)
        let (plan, _) = try await Self.plan(library: lib, known: ["a0", "a1", "a2", "a3"])
        #expect(plan == .only(["n0": 0]))
    }

    @Test func moreNewItemsThanTheLimitIsAFullCheck() async throws {
        let lib = (0..<300).map { "n\($0)" }
        let (plan, _) = try await Self.plan(library: lib, known: [])
        #expect(plan == .fullCheck(reason: ICloudQuickUpdate.reasonTooMany))
    }

    @Test func aScanThatNeverFindsAKnownRunWithinTheLimitIsAFullCheck() async throws {
        // Every other item is on the drive, so the known run never reaches the overlap. 100 new items is under
        // the limit, so the scan limit is what stops it, and it never fetches past that limit.
        let lib = Self.library(300)
        let known = Set(lib.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element))
        var generous = Self.settings
        generous.quickMaxItems = 1_000
        let (plan, offsets) = try await Self.plan(library: lib, known: known, settings: generous)
        #expect(plan == .fullCheck(reason: ICloudQuickUpdate.reasonTooMany))
        #expect(offsets.max().map { $0 < 200 } == true)
    }

    @Test func aQuickUpdateNeedsARecentFullCheckOfTheSameAccountAndLayout() {
        let current = Date()
        let onDrive: Set<String> = ["a0"]
        let recent = Self.point(lastFullWalk: current - Self.day)
        #expect(ICloudQuickUpdate.isEligible(point: recent, account: Self.account, layout: .month, known: onDrive,
                                             missing: [], now: current, maxAge: 30 * Self.day))
        func eligible(_ point: ICloudResumePoint?, account: String = Self.account, layout: FolderLayout = .month,
                      known: Set<String> = onDrive, missing: Set<String> = []) -> Bool {
            ICloudQuickUpdate.isEligible(point: point, account: account, layout: layout, known: known, missing: missing,
                                         now: current, maxAge: 30 * Self.day)
        }
        #expect(!eligible(Self.point(lastFullWalk: current - 31 * Self.day)))
        #expect(!eligible(Self.point(lastFullWalk: nil)))
        #expect(!eligible(nil))
        #expect(!eligible(recent, account: "other"))
        #expect(!eligible(recent, layout: .flat))
        #expect(!eligible(recent, known: []))
        #expect(!eligible(recent, missing: ["a1"]))
        #expect(!eligible(Self.point(lastFullWalk: current + Self.day)))
    }

    @Test func theDefaultsAreAMonthAndTheDocumentedLimits() {
        let defaults = ICloudResumeSettings()
        #expect(defaults.fullCheckInterval == 30 * 24 * 60 * 60)
        #expect(defaults.quickScanLimit == 5_000)
        #expect(defaults.quickMaxItems == 2_000)
    }
}
