import Foundation
import Testing
@testable import Uncloud

/// Shared inputs for the Dates tests: calendars with a fixed time zone, and entries with and without dates.
enum BrowseDateFixtures {
    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        return calendar
    }

    /// An instant at a wall-clock time in a zone, so the tests say what the photo's own clock read.
    static func instant(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, second: Int = 0,
        zone identifier: String = "Europe/Rome"
    ) -> Date {
        calendar(identifier).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )) ?? Date(timeIntervalSince1970: 0)
    }

    static func dated(_ path: String, _ date: Date?, latitude: Double? = nil, longitude: Double? = nil) -> BrowseEntry {
        BrowseEntry(path: path, size: 10, modified: 1, latitude: latitude, longitude: longitude, date: date, camera: nil)
    }

    /// (year, month, photo count) for every month of a timeline, oldest first.
    static func months(_ timeline: BrowseTimeline) -> [(year: Int, month: Int, count: Int)] {
        timeline.years.flatMap { year in year.months.map { (year: year.year, month: $0.month, count: $0.count) } }
    }
}

@Suite("BrowseDates")
struct BrowseDatesTests {
    private let rome = BrowseDateFixtures.calendar("Europe/Rome")

    // MARK: - Grouping

    @Test func groupsEntriesIntoYearsAndMonthsWithoutEmptyOnes() {
        let entries = [
            BrowseDateFixtures.dated("a.jpg", BrowseDateFixtures.instant(2025, 3, 2)),
            BrowseDateFixtures.dated("b.jpg", BrowseDateFixtures.instant(2025, 3, 9)),
            BrowseDateFixtures.dated("c.jpg", BrowseDateFixtures.instant(2026, 7, 1)),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(timeline.years.map(\.year) == [2025, 2026])
        #expect(timeline.years[0].months.map(\.month) == [3])
        #expect(timeline.years[0].count == 2)
        #expect(timeline.years[0].months[0].paths == ["a.jpg", "b.jpg"])
        #expect(timeline.years[1].months.map(\.month) == [7])
        #expect(timeline.years[1].count == 1)
    }

    @Test func yearsListNewestFirstWithDecemberToJanuaryAndOldestFirstIsTheExactReverse() {
        let entries = [
            BrowseDateFixtures.dated("jan.jpg", BrowseDateFixtures.instant(2025, 1, 5)),
            BrowseDateFixtures.dated("dec.jpg", BrowseDateFixtures.instant(2025, 12, 5)),
            BrowseDateFixtures.dated("old.jpg", BrowseDateFixtures.instant(2024, 6, 5)),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        let newest = timeline.years(.newestFirst)
        #expect(newest.map(\.year) == [2025, 2024])
        #expect(newest[0].months.map(\.month) == [12, 1])
        let oldest = timeline.years(.oldestFirst)
        #expect(oldest.map(\.year) == [2024, 2025])
        #expect(oldest[1].months.map(\.month) == [1, 12])
    }

    @Test func undatedPhotosGoToNoDateSortedByPathAndAreNotRanked() {
        let entries = [
            BrowseDateFixtures.dated("z.png", nil),
            BrowseDateFixtures.dated("a.png", nil),
            BrowseDateFixtures.dated("dated.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(timeline.noDate == ["a.png", "z.png"])
        #expect(timeline.rank["a.png"] == nil)
        #expect(timeline.rank["dated.jpg"] == 0)
        #expect(timeline.firstRowID(.newestFirst) == "month:2024-07")

        let onlyUndated = BrowseDates.timeline(from: [BrowseDateFixtures.dated("z.png", nil)], calendar: rome)
        #expect(onlyUndated.firstRowID(.newestFirst) == BrowseTimeline.noDateID)
        #expect(onlyUndated.firstRowID(.oldestFirst) == BrowseTimeline.noDateID)
        #expect(BrowseDates.timeline(from: [], calendar: rome).firstRowID(.newestFirst) == nil)
    }

    @Test func aDatedPhotoGroupsByItsDateNotItsFolder() {
        let entries = [BrowseDateFixtures.dated("2024/07/moved.jpg", BrowseDateFixtures.instant(2025, 3, 1))]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(BrowseDateFixtures.months(timeline).map { [$0.year, $0.month] } == [[2025, 3]])
    }

    @Test func folderMonthSortsAtTheStartOfItsMonthInBothOrders() {
        let entries = [
            BrowseDateFixtures.dated("2024/07/b.jpg", BrowseDateFixtures.instant(2024, 7, 10)),
            BrowseDateFixtures.dated("2024/07/a.jpg", nil),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        let monthID = "month:2024-07"
        #expect(timeline.paths(forRowID: monthID, order: .oldestFirst) == ["2024/07/a.jpg", "2024/07/b.jpg"])
        #expect(timeline.paths(forRowID: monthID, order: .newestFirst) == ["2024/07/b.jpg", "2024/07/a.jpg"])
    }

    // MARK: - Folder month

    @Test func folderMonthReadsTheLastMatchingFolder() {
        #expect(BrowseDates.folderMonth("2024/07/a.jpg")?.year == 2024)
        #expect(BrowseDates.folderMonth("2024/07/a.jpg")?.month == 7)
        #expect(BrowseDates.folderMonth("Italy/Rome/2024-07/a.jpg")?.month == 7)
        #expect(BrowseDates.folderMonth("Album/2024/07/a.jpg")?.year == 2024)
        #expect(BrowseDates.folderMonth("2024-07/sub/a.jpg")?.month == 7)
        #expect(BrowseDates.folderMonth("2024/07/2023-05/a.jpg")?.month == 5)
    }

    @Test func folderMonthRejectsWhatIsNotAMonth() {
        #expect(BrowseDates.folderMonth("Undated/a.jpg") == nil)
        #expect(BrowseDates.folderMonth("a.jpg") == nil)
        #expect(BrowseDates.folderMonth("2024/13/a.jpg") == nil)
        #expect(BrowseDates.folderMonth("1850/01/a.jpg") == nil)
        #expect(BrowseDates.folderMonth("Photos 2024-07.jpg") == nil)
        #expect(BrowseDates.folderMonth("2024/7/a.jpg") == nil)
    }

    // MARK: - Sorting

    @Test func sortedPutsDatedPhotosInOrderAndUndatedLastByPath() {
        let rank = ["late.jpg": 2, "early.jpg": 0, "middle.jpg": 1]
        let paths = ["zz.png", "late.jpg", "aa.png", "early.jpg", "middle.jpg"]
        #expect(BrowseDates.sorted(paths, rank: rank, order: .oldestFirst) == ["early.jpg", "middle.jpg", "late.jpg", "aa.png", "zz.png"])
        #expect(BrowseDates.sorted(paths, rank: rank, order: .newestFirst) == ["late.jpg", "middle.jpg", "early.jpg", "aa.png", "zz.png"])
    }

    @Test func equalDatesBreakByPathAndNewestFirstReversesThemExactly() {
        let date = BrowseDateFixtures.instant(2026, 10, 18, 9)
        let entries = [
            BrowseDateFixtures.dated("IMG_2.jpg", date),
            BrowseDateFixtures.dated("IMG_1.jpg", date),
            BrowseDateFixtures.dated("IMG_3.jpg", date),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        let oldest = timeline.paths(forRowID: "month:2026-10", order: .oldestFirst)
        #expect(oldest == ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        #expect(timeline.paths(forRowID: "month:2026-10", order: .newestFirst) == Array(oldest.reversed()))
    }

    @Test func pathsForRowsAreOrderedAndNoDateIsByPathInBothOrders() {
        let entries = [
            BrowseDateFixtures.dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
            BrowseDateFixtures.dated("2024/12/b.jpg", BrowseDateFixtures.instant(2024, 12, 24)),
            BrowseDateFixtures.dated("zz.png", nil),
            BrowseDateFixtures.dated("aa.png", nil),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(timeline.paths(forRowID: "year:2024", order: .oldestFirst) == ["2024/07/a.jpg", "2024/12/b.jpg"])
        #expect(timeline.paths(forRowID: "year:2024", order: .newestFirst) == ["2024/12/b.jpg", "2024/07/a.jpg"])
        #expect(timeline.paths(forRowID: "month:2024-12", order: .oldestFirst) == ["2024/12/b.jpg"])
        #expect(timeline.paths(forRowID: BrowseTimeline.noDateID, order: .oldestFirst) == ["aa.png", "zz.png"])
        #expect(timeline.paths(forRowID: BrowseTimeline.noDateID, order: .newestFirst) == ["aa.png", "zz.png"])
    }

    // MARK: - Time zones

    @Test func aMomentIsGroupedInTheMacsZone() {
        // 22:30 UTC on October 31: still October in Rome and New York.
        let late = BrowseDateFixtures.instant(2026, 10, 31, 23, 30, zone: "Europe/Rome")
        #expect(BrowseDates.timeline(from: [BrowseDateFixtures.dated("a.jpg", late)], calendar: BrowseDateFixtures.calendar("America/New_York")).years[0].months[0].month == 10)
        #expect(BrowseDates.timeline(from: [BrowseDateFixtures.dated("a.jpg", late)], calendar: rome).years[0].months[0].month == 10)

        // 00:30 on November 1 in Tokyo is 15:30 UTC on October 31: October in New York, November in Tokyo.
        let tokyo = BrowseDateFixtures.instant(2026, 11, 1, 0, 30, zone: "Asia/Tokyo")
        let newYork = BrowseDates.timeline(from: [BrowseDateFixtures.dated("a.jpg", tokyo)], calendar: BrowseDateFixtures.calendar("America/New_York"))
        #expect(newYork.years[0].months[0].month == 10)
        let japan = BrowseDates.timeline(from: [BrowseDateFixtures.dated("a.jpg", tokyo)], calendar: BrowseDateFixtures.calendar("Asia/Tokyo"))
        #expect(japan.years[0].months[0].month == 11)
    }

    @Test func daylightSavingTimeChangesLandInTheirMonths() {
        let entries = [
            BrowseDateFixtures.dated("spring.jpg", BrowseDateFixtures.instant(2026, 3, 29, 2, 30)),
            BrowseDateFixtures.dated("autumn.jpg", BrowseDateFixtures.instant(2026, 10, 25, 2, 30)),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(BrowseDateFixtures.months(timeline).map(\.month) == [3, 10])
    }

    @Test func newYearSplitsYearsAtMidnightLocally() {
        let entries = [
            BrowseDateFixtures.dated("old.jpg", BrowseDateFixtures.instant(2026, 12, 31, 23, 59, second: 59)),
            BrowseDateFixtures.dated("new.jpg", BrowseDateFixtures.instant(2027, 1, 1, 0, 0, second: 0)),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(timeline.years.map(\.year) == [2026, 2027])
    }

    @Test func datesBeforeTheEpochAndFarInTheFutureGroupCorrectly() {
        let entries = [
            BrowseDateFixtures.dated("old.jpg", BrowseDateFixtures.instant(1965, 6, 1)),
            BrowseDateFixtures.dated("future.jpg", BrowseDateFixtures.instant(2099, 12, 31)),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        #expect(timeline.years.map(\.year) == [1965, 2099])
        #expect(timeline.years.map(\.count) == [1, 1])
    }

    // MARK: - Titles and search

    @Test func titlesFollowTheLocale() {
        let month = BrowseMonth(year: 2026, month: 10, start: BrowseDateFixtures.instant(2026, 10, 1), paths: [])
        let english = Locale(identifier: "en_US")
        #expect(BrowseDates.monthTitle(month, calendar: rome, locale: english) == "October")
        #expect(BrowseDates.fullMonthTitle(month, calendar: rome, locale: english) == "October 2026")
        #expect(BrowseDates.monthTitle(month, calendar: rome, locale: Locale(identifier: "fr_FR")) == "octobre")
        #expect(BrowseDates.yearTitle(2026) == "2026")
        #expect(BrowseDates.yearTitle(2026) == String(2026))
    }

    @Test func searchKeepsMatchingMonthsAndTheirYearsAndDropsNoDate() {
        let entries = [
            BrowseDateFixtures.dated("oct25.jpg", BrowseDateFixtures.instant(2025, 10, 4)),
            BrowseDateFixtures.dated("jul24.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
            BrowseDateFixtures.dated("feb24.jpg", BrowseDateFixtures.instant(2024, 2, 4)),
            BrowseDateFixtures.dated("nodate.png", nil),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        let october = timeline.filtered("oct", calendar: rome, locale: Locale(identifier: "en_US"))
        #expect(october.years.map(\.year) == [2025])
        #expect(october.noDate.isEmpty)

        let year2024 = timeline.filtered("2024", calendar: rome, locale: Locale(identifier: "en_US"))
        #expect(year2024.years.map(\.year) == [2024])
        #expect(year2024.years[0].months.map(\.month) == [2, 7])
        #expect(year2024.years[0].count == 2)
    }

    // MARK: - Days and place names

    @Test func daysSplitAMonthByLocalDayInTheGivenOrder() {
        // 23:30 and 00:30 local on October 17 are on different UTC days, but one local day.
        let entries = [
            BrowseDateFixtures.dated("late.jpg", BrowseDateFixtures.instant(2026, 10, 17, 23, 30)),
            BrowseDateFixtures.dated("early.jpg", BrowseDateFixtures.instant(2026, 10, 17, 0, 30)),
            BrowseDateFixtures.dated("next.jpg", BrowseDateFixtures.instant(2026, 10, 18, 9, 0)),
            BrowseDateFixtures.dated("2026/10/undated.jpg", nil),
        ]
        let timeline = BrowseDates.timeline(from: entries, calendar: rome)
        let month = timeline.years[0].months[0]
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

        let oldest = BrowseDates.days(of: month, entries: entryMap, calendar: rome, order: .oldestFirst)
        #expect(oldest.map(\.paths) == [["2026/10/undated.jpg"], ["early.jpg", "late.jpg"], ["next.jpg"]])
        #expect(oldest.map(\.isMonthOnly) == [true, false, false])

        let newest = BrowseDates.days(of: month, entries: entryMap, calendar: rome, order: .newestFirst)
        #expect(newest.map(\.paths) == [["next.jpg"], ["late.jpg", "early.jpg"], ["2026/10/undated.jpg"]])
        #expect(newest.last?.isMonthOnly == true)
        #expect(BrowseDates.dayTitle(newest[0], calendar: rome, locale: Locale(identifier: "en_US")) == "Sunday, October 18")
        #expect(BrowseDates.dayTitle(newest[2], calendar: rome, locale: Locale(identifier: "en_US")) == "October 2026")
    }

    @Test func aYearsMonthSectionsFollowTheOrder() {
        let entries = [
            BrowseDateFixtures.dated("jan.jpg", BrowseDateFixtures.instant(2025, 1, 5)),
            BrowseDateFixtures.dated("mar-a.jpg", BrowseDateFixtures.instant(2025, 3, 2)),
            BrowseDateFixtures.dated("mar-b.jpg", BrowseDateFixtures.instant(2025, 3, 9)),
        ]
        let year = BrowseDates.timeline(from: entries, calendar: rome).years[0]
        #expect(BrowseDates.monthSections(of: year, order: .oldestFirst).map(\.month) == [1, 3])
        let newest = BrowseDates.monthSections(of: year, order: .newestFirst)
        #expect(newest.map(\.month) == [3, 1])
        #expect(newest[0].paths == ["mar-b.jpg", "mar-a.jpg"])
    }

    @Test func placeSummaryNamesUpToTwoPlacesThenCountsTheRest() {
        #expect(BrowseDates.placeSummary(["Rome"]) == "Rome")
        #expect(BrowseDates.placeSummary(["Rome", "Florence", "Rome"]) == "Rome, Florence")
        #expect(BrowseDates.placeSummary(["Rome", "Florence", "Pisa", "Siena", "Lucca"]) == "Rome, Florence and 3 more")
        #expect(BrowseDates.placeSummary([]) == nil)
    }

    // MARK: - Scale

    @Test func aNinetyThousandPhotoLibraryBuildsQuickly() {
        var entries: [BrowseEntry] = []
        entries.reserveCapacity(90_000)
        for index in 0..<90_000 {
            let path = "photos/IMG_\(index).jpg"
            if index % 50 == 0 {
                entries.append(BrowseDateFixtures.dated(path, nil))
            } else if index % 33 == 0 {
                entries.append(BrowseDateFixtures.dated("2015/01/IMG_\(index).jpg", nil))
            } else {
                entries.append(BrowseDateFixtures.dated(path, Date(timeIntervalSince1970: 1_420_000_000 + Double(index) * 5_000)))
            }
        }
        let clock = ContinuousClock()
        var timeline = BrowseTimeline()
        let elapsed = clock.measure {
            timeline = BrowseDates.timeline(from: entries, calendar: rome)
        }
        #expect(elapsed < .seconds(2))
        let datedCount = timeline.years.reduce(0) { $0 + $1.count }
        #expect(datedCount + timeline.noDate.count == 90_000)
        #expect(timeline.rank.count == datedCount)
    }
}
