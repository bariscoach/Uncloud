import Foundation
import Testing
@testable import Uncloud

@Suite("ReorganizePlanner")
struct ReorganizePlannerTests {
    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                             zone: String = "America/New_York") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func input(
        files: [(name: String, size: Int64, modified: Date)],
        records: [String: [String]],
        targets: [String: Set<String>] = [:],
        created: [String: Date] = [:]
    ) -> ReorganizePlanner.Input {
        var listing: [String: ReorganizePlanner.RootFile] = [:]
        for file in files {
            listing[file.name] = ReorganizePlanner.RootFile(size: file.size, modified: file.modified.timeIntervalSince1970)
        }
        return ReorganizePlanner.Input(
            records: records,
            rootListing: listing,
            targetListings: targets,
            createdByKey: created,
            calendar: newYork
        )
    }

    /// The old and new path of every move, in plan order.
    private static func pairs(_ plan: ReorganizePlanner.Plan) -> [String] {
        plan.moves.map { "\($0.old) -> \($0.new)" }
    }

    @Test func livePhotoAndSidecarGoToOneMonth() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [
                ("IMG_1.HEIC", 100, Self.date(2024, 7, 15, 12)),
                ("IMG_1.MOV", 200, Self.date(2024, 7, 15, 12)),
                ("IMG_1.HEIC.xmp", 5, Self.date(2024, 7, 15, 12)),
                ("IMG_6.HEIC", 300, Self.date(2024, 8, 2, 12)),
                ("IMG_9.MOV", 400, Self.date(2024, 9, 3, 12)),
            ],
            records: [
                "icloud-id:A": ["IMG_1.HEIC", "IMG_1.MOV", "IMG_1.HEIC.xmp"],
                "icloud-id:B": ["IMG_6.HEIC"],
                "icloud-id:M": ["IMG_9.MOV"],
            ]
        ))
        #expect(Self.pairs(plan) == [
            "IMG_1.HEIC -> 2024/07/IMG_1.HEIC",
            "IMG_1.HEIC.xmp -> 2024/07/IMG_1.HEIC.xmp",
            "IMG_1.MOV -> 2024/07/IMG_1.MOV",
            "IMG_6.HEIC -> 2024/08/IMG_6.HEIC",
            "IMG_9.MOV -> 2024/09/IMG_9.MOV",
        ])
        #expect(plan.moves.map(\.index) == [0, 1, 2, 3, 4])
        #expect(plan.months == ["2024/07", "2024/08", "2024/09"])
        #expect(plan.staying == 0)
        #expect(plan.collisions == 0)
    }

    @Test func icloudpdSuffixIsDroppedAndSidecarFollows() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [
                ("IMG_1-2483921.HEIC", 2_483_921, Self.date(2024, 7, 15, 12)),
                ("IMG_1-2483921.xmp", 4, Self.date(2024, 7, 15, 12)),
            ],
            records: ["icloud-id:A": ["IMG_1-2483921.HEIC", "IMG_1-2483921.xmp"]]
        ))
        #expect(Self.pairs(plan) == [
            "IMG_1-2483921.HEIC -> 2024/07/IMG_1.HEIC",
            "IMG_1-2483921.xmp -> 2024/07/IMG_1.xmp",
        ])
        #expect(plan.renamedForICloud == 1)
        #expect(plan.collisions == 0)
    }

    @Test func icloudpdSuffixIsKeptWhenThePlainNameIsTaken() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [
                ("IMG_1-2483921.HEIC", 2_483_921, Self.date(2024, 7, 15, 12)),
                ("IMG_1-2483921.xmp", 4, Self.date(2024, 7, 15, 12)),
            ],
            records: ["icloud-id:A": ["IMG_1-2483921.HEIC", "IMG_1-2483921.xmp"]],
            targets: ["2024/07": ["IMG_1.HEIC"]]
        ))
        #expect(Self.pairs(plan) == [
            "IMG_1-2483921.HEIC -> 2024/07/IMG_1-2483921.HEIC",
            "IMG_1-2483921.xmp -> 2024/07/IMG_1-2483921.xmp",
        ])
        #expect(plan.renamedForICloud == 0)
        #expect(plan.collisions == 1)
    }

    @Test func twoItemsWantingTheSameNameTheFirstKeepsItAndTheSecondGetsItsSize() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [
                ("IMG_2-500.JPG", 500, Self.date(2024, 7, 2, 12)),
                ("IMG_2.JPG", 77, Self.date(2024, 7, 3, 12)),
            ],
            records: ["icloud-id:A": ["IMG_2-500.JPG"], "icloud-id:B": ["IMG_2.JPG"]]
        ))
        #expect(Self.pairs(plan) == [
            "IMG_2-500.JPG -> 2024/07/IMG_2.JPG",
            "IMG_2.JPG -> 2024/07/IMG_2-77.JPG",
        ])
        #expect(plan.collisions == 1)
        #expect(plan.renamedForICloud == 1)
    }

    @Test func suffixGoesOnToTheSecondCounterWhenTheSizeNameIsTaken() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_3.JPG", 42, Self.date(2024, 7, 2, 12))],
            records: ["icloud-id:A": ["IMG_3.JPG"]],
            targets: ["2024/07": ["IMG_3.JPG", "IMG_3-42.JPG"]]
        ))
        #expect(Self.pairs(plan) == ["IMG_3.JPG -> 2024/07/IMG_3-42_2.JPG"])
    }

    @Test func unrecordedAndDotFilesStayWhereTheyAre() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [
                ("IMG_1.HEIC", 100, Self.date(2024, 7, 15, 12)),
                ("notes.txt", 9, Self.date(2024, 7, 15, 12)),
                ("._IMG_1.HEIC", 4096, Self.date(2024, 7, 15, 12)),
                (".photo-export", 0, Self.date(2024, 7, 15, 12)),
            ],
            records: ["icloud-id:A": ["IMG_1.HEIC"]]
        ))
        #expect(Self.pairs(plan) == ["IMG_1.HEIC -> 2024/07/IMG_1.HEIC"])
        #expect(plan.staying == 3)
    }

    @Test func itemAlreadyInAFolderIsNotMoved() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_5.JPG", 10, Self.date(2024, 7, 2, 12))],
            records: ["icloud-id:S": ["2024/07/IMG_9.HEIC"], "icloud-id:A": ["IMG_5.JPG"]]
        ))
        #expect(Self.pairs(plan) == ["IMG_5.JPG -> 2024/07/IMG_5.JPG"])
        #expect(plan.staying == 0)
    }

    @Test func icloudIDWithoutCatalogDateUsesTheFileTimeInTheCalendarZone() {
        // 2024-08-01 02:00 UTC is 2024-07-31 22:00 in New York, so the month is July.
        let modified = Self.date(2024, 8, 1, 2, zone: "UTC")
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_5.HEIC", 10, modified)],
            records: ["icloud-id:X": ["IMG_5.HEIC"]]
        ))
        #expect(Self.pairs(plan) == ["IMG_5.HEIC -> 2024/07/IMG_5.HEIC"])
    }

    @Test func icloudIDWithCatalogDateUsesTheCatalogDate() {
        let modified = Self.date(2024, 8, 1, 2, zone: "UTC")
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_5.HEIC", 10, modified)],
            records: ["icloud-id:X": ["IMG_5.HEIC"]],
            created: ["icloud-id:X": Self.date(2024, 8, 1, 10)]
        ))
        #expect(Self.pairs(plan) == ["IMG_5.HEIC -> 2024/08/IMG_5.HEIC"])
    }

    @Test func pathOnlyICloudRecordsIgnoreCatalogDatesAndUseTheFileTime() {
        let modified = Self.date(2024, 8, 1, 2, zone: "UTC")
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_5.HEIC", 10, modified)],
            records: ["icloud:X": ["IMG_5.HEIC"]],
            created: ["icloud:X": Self.date(2024, 8, 1, 10)]
        ))
        #expect(Self.pairs(plan) == ["IMG_5.HEIC -> 2024/07/IMG_5.HEIC"])
    }

    @Test func iCloudItemsNeverGoToUndated() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_7.JPG", 10, Self.date(2024, 7, 2, 12))],
            records: ["icloud-partial:P": ["IMG_7.JPG"]]
        ))
        #expect(Self.pairs(plan) == ["IMG_7.JPG -> 2024/07/IMG_7.JPG"])
        #expect(!plan.months.contains("Undated"))
    }

    @Test func photosLibraryItemWithoutADateGoesToUndated() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_5.JPG", 10, Self.date(2024, 7, 2, 12))],
            records: ["ABC-LOCAL-ID": ["IMG_5.JPG"]]
        ))
        #expect(Self.pairs(plan) == ["IMG_5.JPG -> Undated/IMG_5.JPG"])
        #expect(plan.months == ["Undated"])
    }

    @Test func photosLibraryItemWithADateGoesToItsMonth() {
        let plan = ReorganizePlanner.plan(Self.input(
            files: [("IMG_5.JPG", 10, Self.date(2024, 7, 2, 12))],
            records: ["ABC-LOCAL-ID": ["IMG_5.JPG"]],
            created: ["ABC-LOCAL-ID": Self.date(2023, 12, 31, 23)]
        ))
        #expect(Self.pairs(plan) == ["IMG_5.JPG -> 2023/12/IMG_5.JPG"])
    }

    @Test func theSameInputGivesTheSamePlan() {
        let files: [(name: String, size: Int64, modified: Date)] = [
            ("IMG_2-500.JPG", 500, Self.date(2024, 7, 2, 12)),
            ("IMG_2.JPG", 77, Self.date(2024, 7, 3, 12)),
            ("IMG_1-2483921.HEIC", 2_483_921, Self.date(2024, 7, 15, 12)),
            ("IMG_1-2483921.xmp", 4, Self.date(2024, 7, 15, 12)),
        ]
        let records = [
            "icloud-id:A": ["IMG_2-500.JPG"],
            "icloud-id:B": ["IMG_2.JPG"],
            "icloud-id:C": ["IMG_1-2483921.HEIC", "IMG_1-2483921.xmp"],
        ]
        let first = ReorganizePlanner.plan(Self.input(files: files, records: records))
        let second = ReorganizePlanner.plan(Self.input(files: Array(files.reversed()), records: records))
        #expect(first == second)
    }
}
