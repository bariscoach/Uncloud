import Foundation
import Testing
@testable import Uncloud

/// The Export Photos by Date walk and its date presets, against a fake library (newest first). No Apple account, no network.
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

    // MARK: - Date presets

    /// A fixed calendar in UTC, so the dates below don't depend on the machine's time zone.
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        utc.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    @Test func last30DaysCovers30CalendarDaysIncludingToday() {
        let now = Self.day(2026, 10, 22, hour: 15, minute: 30)
        let days = ExportSince.DatePreset.last30Days.days(now: now, calendar: Self.utc)
        #expect(days?.from == Self.day(2026, 9, 23))
        #expect(days?.to == Self.day(2026, 10, 22))
    }

    @Test func last7DaysCovers7CalendarDaysIncludingToday() {
        let now = Self.day(2026, 10, 22, hour: 0, minute: 5)
        let days = ExportSince.DatePreset.last7Days.days(now: now, calendar: Self.utc)
        #expect(days?.from == Self.day(2026, 10, 16))
        #expect(days?.to == Self.day(2026, 10, 22))
    }

    @Test func last30DaysCrossesAMonthAndLeapDay() {
        let now = Self.day(2028, 3, 10, hour: 12)
        let days = ExportSince.DatePreset.last30Days.days(now: now, calendar: Self.utc)
        #expect(days?.from == Self.day(2028, 2, 10))
        #expect(days?.to == Self.day(2028, 3, 10))
    }

    @Test func thisYearStartsOnJanuaryFirst() {
        let now = Self.day(2026, 10, 22, hour: 18)
        let days = ExportSince.DatePreset.thisYear.days(now: now, calendar: Self.utc)
        #expect(days?.from == Self.day(2026, 1, 1))
        #expect(days?.to == Self.day(2026, 10, 22))
    }

    @Test func thisYearOnJanuaryFirstIsTheFirstDayOnly() {
        let now = Self.day(2027, 1, 1, hour: 9)
        let days = ExportSince.DatePreset.thisYear.days(now: now, calendar: Self.utc)
        #expect(days?.from == Self.day(2027, 1, 1))
        #expect(days?.to == Self.day(2027, 1, 1))
    }

    @Test func customHasNoPresetDates() {
        #expect(ExportSince.DatePreset.custom.days(now: Self.day(2026, 10, 22), calendar: Self.utc) == nil)
    }

    @Test func endOfDayIsTheLastSecondOfTheCalendarDay() {
        #expect(ExportSince.endOfDay(Self.day(2026, 10, 22, hour: 9), calendar: Self.utc) == Self.day(2026, 10, 22, hour: 23, minute: 59, second: 59))
        #expect(ExportSince.endOfDay(Self.day(2028, 2, 28), calendar: Self.utc) == Self.day(2028, 2, 28, hour: 23, minute: 59, second: 59))
        #expect(ExportSince.endOfDay(Self.day(2028, 2, 29, hour: 23, minute: 59), calendar: Self.utc) == Self.day(2028, 2, 29, hour: 23, minute: 59, second: 59))
    }

    @Test func aRangeEndingOnADayTakesInItsLastSecond() async throws {
        let dayStart = Self.day(2026, 10, 22)
        let library = FakeLibrary(items: [
            Self.asset("late", added: dayStart.addingTimeInterval(23 * 3_600 + 59 * 60 + 59).timeIntervalSince1970 + 100),
            Self.asset("last", added: nil, created: dayStart.addingTimeInterval(23 * 3_600 + 59 * 60 + 59).timeIntervalSince1970),
            Self.asset("next", added: nil, created: dayStart.addingTimeInterval(24 * 3_600).timeIntervalSince1970),
            Self.asset("early", added: nil, created: dayStart.timeIntervalSince1970 - 1),
        ])
        let end = ExportSince.endOfDay(dayStart, calendar: Self.utc)
        let result = try await ExportSince.iCloudItems(takenFrom: dayStart, to: end, fetcher: library)
        #expect(result.items == ["last": 1])
    }

    // MARK: - Count text

    @Test func countTextNamesThePhotosToExportAndTheBackedUpOnes() {
        #expect(ExportSince.countText(toExport: 312, backedUp: 4, isAtLeast: false) == "312 photos to export · 4 already backed up")
        #expect(ExportSince.countText(toExport: 312, backedUp: 0, isAtLeast: false) == "312 photos to export")
        #expect(ExportSince.countText(toExport: 1, backedUp: 0, isAtLeast: false) == "1 photo to export")
        #expect(ExportSince.countText(toExport: 1, backedUp: 1, isAtLeast: false) == "1 photo to export · 1 already backed up")
    }

    @Test func countTextSaysWhenEverythingIsBackedUp() {
        #expect(ExportSince.countText(toExport: 0, backedUp: 4, isAtLeast: false) == "All 4 photos are already backed up")
        #expect(ExportSince.countText(toExport: 0, backedUp: 1, isAtLeast: false) == "All 1 photo is already backed up")
        #expect(ExportSince.countText(toExport: 0, backedUp: 0, isAtLeast: false) == "No photos taken in this range")
    }

    @Test func countTextSaysWhenTheWalkStoppedAtTheLimit() {
        #expect(ExportSince.countText(toExport: 20_000, backedUp: 0, isAtLeast: true) == "More than 20,000 photos")
    }
}
