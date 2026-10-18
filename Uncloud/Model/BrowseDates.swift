import Foundation

/// The order of Browse Backup's dates and photos. The raw value is the stored setting.
enum BrowseSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        }
    }

    static let defaultsKey = "browseSortOrder"
}

/// One calendar month of photos, in the grouping calendar. `paths` are oldest first.
struct BrowseMonth: Identifiable, Equatable, Sendable {
    let year: Int
    let month: Int
    /// The first instant of the month, for its titles.
    let start: Date
    var paths: [String]

    var id: String { "month:\(year)-\(month < 10 ? "0" : "")\(month)" }
    var count: Int { paths.count }
}

/// One calendar year of photos. `months` are January first, and only months with photos are listed.
struct BrowseYear: Identifiable, Equatable, Sendable {
    let year: Int
    var months: [BrowseMonth]
    var count: Int

    var id: String { "year:\(year)" }
}

/// The Dates view's data, built once per index change. Everything is stored oldest first; `BrowseSortOrder` reverses
/// at read time.
struct BrowseTimeline: Equatable, Sendable {
    static let noDateID = "no-date"

    var years: [BrowseYear] = []
    /// Photos with no date and no folder month, by path.
    var noDate: [String] = []
    /// Each dated photo's place in the whole backup, oldest first. Used to sort any set of paths without re-reading dates.
    var rank: [String: Int] = [:]

    var isEmpty: Bool { years.isEmpty && noDate.isEmpty }

    /// The years and their months in the given order.
    func years(_ order: BrowseSortOrder) -> [BrowseYear] {
        guard order == .newestFirst else { return years }
        return years.reversed().map { year in
            var year = year
            year.months.reverse()
            return year
        }
    }

    /// The photos of a year, a month or No Date, in the given order. No Date is by path in both orders.
    func paths(forRowID id: String, order: BrowseSortOrder) -> [String] {
        if id == Self.noDateID { return noDate }
        if let year = years.first(where: { $0.id == id }) {
            let paths = year.months.flatMap(\.paths)
            return order == .oldestFirst ? paths : Array(paths.reversed())
        }
        if let month = month(withID: id) {
            return Self.ordered(month.paths, order)
        }
        return []
    }

    func month(withID id: String) -> BrowseMonth? {
        for year in years {
            if let month = year.months.first(where: { $0.id == id }) { return month }
        }
        return nil
    }

    /// The row the list selects when the user hasn't picked one: the first month in the order, else No Date.
    func firstRowID(_ order: BrowseSortOrder) -> String? {
        if let month = years(order).first?.months.first { return month.id }
        return noDate.isEmpty ? nil : Self.noDateID
    }

    func hasRow(_ id: String) -> Bool {
        id == Self.noDateID ? !noDate.isEmpty : yearID(containing: id) != nil
    }

    /// The year row that holds a month row, or the year itself.
    func yearID(containing rowID: String) -> String? {
        years.first { $0.id == rowID || $0.months.contains { $0.id == rowID } }?.id
    }

    /// The years and months whose full title ("October 2026") contains the query. No Date never matches.
    func filtered(_ query: String, calendar: Calendar, locale: Locale) -> BrowseTimeline {
        var result = BrowseTimeline()
        result.rank = rank
        result.years = years.compactMap { year in
            let months = year.months.filter {
                BrowseDates.fullMonthTitle($0, calendar: calendar, locale: locale).localizedStandardContains(query)
            }
            guard !months.isEmpty else { return nil }
            return BrowseYear(year: year.year, months: months, count: months.reduce(0) { $0 + $1.count })
        }
        return result
    }

    private static func ordered(_ paths: [String], _ order: BrowseSortOrder) -> [String] {
        order == .oldestFirst ? paths : Array(paths.reversed())
    }
}

/// A day of a month's photos, under its header in the grid. Photos without a time of day (a month folder only) form one
/// section titled with the month.
struct BrowseDaySection: Identifiable, Equatable, Sendable {
    let id: String
    /// The start of the day, or of the month for the month-only section.
    let start: Date
    let isMonthOnly: Bool
    var paths: [String]
    /// The day's named places, as "Rome, Florence and 3 more". Set by the model; nil while names are unknown.
    var placeSummary: String? = nil
}

enum BrowseDates {
    /// Builds the timeline. Sorts once by (date, path), then walks the sorted list. A month boundary is computed only
    /// when the walk crosses one, so calendar calls are per month, not per photo.
    static func timeline(from entries: [BrowseEntry], calendar: Calendar) -> BrowseTimeline {
        var dated: [(date: Date, path: String)] = []
        var undated: [String] = []
        for entry in entries {
            if let date = sortDate(for: entry, calendar: calendar) {
                dated.append((date, entry.path))
            } else {
                undated.append(entry.path)
            }
        }
        dated.sort { $0.date != $1.date ? $0.date < $1.date : $0.path < $1.path }

        var timeline = BrowseTimeline()
        timeline.noDate = undated.sorted()
        timeline.rank.reserveCapacity(dated.count)
        var monthRange: Range<Date>?
        for (index, item) in dated.enumerated() {
            timeline.rank[item.path] = index
            if monthRange?.contains(item.date) != true {
                let parts = calendar.dateComponents([.year, .month], from: item.date)
                let year = parts.year ?? 0
                let month = parts.month ?? 1
                let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? item.date
                let end = calendar.date(byAdding: .month, value: 1, to: start) ?? .distantFuture
                monthRange = start..<end
                if timeline.years.last?.year != year {
                    timeline.years.append(BrowseYear(year: year, months: [], count: 0))
                }
                let yearIndex = timeline.years.count - 1
                if timeline.years[yearIndex].months.last?.month != month {
                    timeline.years[yearIndex].months.append(BrowseMonth(year: year, month: month, start: start, paths: []))
                }
            }
            let yearIndex = timeline.years.count - 1
            let monthIndex = timeline.years[yearIndex].months.count - 1
            timeline.years[yearIndex].months[monthIndex].paths.append(item.path)
            timeline.years[yearIndex].count += 1
        }
        return timeline
    }

    /// The sort key: the capture date, or the start of the folder's month, or nil when the photo has neither (No Date).
    static func sortDate(for entry: BrowseEntry, calendar: Calendar) -> Date? {
        if let date = entry.date { return date }
        guard let folder = folderMonth(entry.path) else { return nil }
        return calendar.date(from: DateComponents(year: folder.year, month: folder.month, day: 1))
    }

    /// The year and month of the last folder that names one: "2024-07" or "2024" then "07". The file name never counts.
    /// Years 1900 to 2100 and months 1 to 12 only.
    static func folderMonth(_ path: String) -> (year: Int, month: Int)? {
        let folders = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        for index in folders.indices.reversed() {
            let folder = folders[index]
            if folder.count == 7, folder.dropFirst(4).first == "-" {
                let yearText = folder.prefix(4)
                let monthText = folder.suffix(2)
                guard isDigits(yearText, count: 4), isDigits(monthText, count: 2),
                      let year = Int(yearText), let month = Int(monthText) else { return nil }
                return valid(year: year, month: month)
            }
            if isDigits(folder, count: 2), index > folders.startIndex, isDigits(folders[index - 1], count: 4),
               let year = Int(folders[index - 1]), let month = Int(folder) {
                return valid(year: year, month: month)
            }
        }
        return nil
    }

    /// A month's photos split by local day, in the given order. The month-only photos (no time of day) form one section,
    /// first in Oldest First and last in Newest First, like the timeline's order.
    static func days(of month: BrowseMonth, entries: [String: BrowseEntry], calendar: Calendar, order: BrowseSortOrder) -> [BrowseDaySection] {
        let ordered = order == .oldestFirst ? month.paths : Array(month.paths.reversed())
        var sections: [BrowseDaySection] = []
        for path in ordered {
            if let date = entries[path]?.date {
                let start = calendar.startOfDay(for: date)
                if let last = sections.last, !last.isMonthOnly, last.start == start {
                    sections[sections.count - 1].paths.append(path)
                } else {
                    sections.append(BrowseDaySection(id: dayID(start, calendar: calendar), start: start, isMonthOnly: false, paths: [path]))
                }
            } else if let last = sections.last, last.isMonthOnly {
                sections[sections.count - 1].paths.append(path)
            } else {
                sections.append(BrowseDaySection(id: "undated:\(month.id)", start: month.start, isMonthOnly: true, paths: [path]))
            }
        }
        return sections
    }

    /// A year's months, in the given order, each with its paths in that order too.
    static func monthSections(of year: BrowseYear, order: BrowseSortOrder) -> [BrowseMonth] {
        guard order == .newestFirst else { return year.months }
        return year.months.reversed().map { month in
            var month = month
            month.paths.reverse()
            return month
        }
    }

    /// "Rome, Florence", "Rome, Florence and 3 more", or nil: the distinct place titles, in photo order.
    static func placeSummary(_ titles: [String]) -> String? {
        var distinct: [String] = []
        for title in titles where !distinct.contains(title) {
            distinct.append(title)
        }
        switch distinct.count {
        case 0: return nil
        case 1, 2: return distinct.joined(separator: ", ")
        default: return "\(distinct[0]), \(distinct[1]) and \(distinct.count - 2) more"
        }
    }

    /// "Sunday, October 18", or "October 2026" for the month-only section.
    static func dayTitle(_ section: BrowseDaySection, calendar: Calendar, locale: Locale) -> String {
        if section.isMonthOnly {
            return section.start.formatted(monthStyle(calendar: calendar, locale: locale).month(.wide).year(.defaultDigits))
        }
        return section.start.formatted(monthStyle(calendar: calendar, locale: locale).weekday(.wide).month(.wide).day())
    }

    /// Orders paths by their rank in the given order. Paths without a rank go last, by path, in both orders.
    static func sorted(_ paths: [String], rank: [String: Int], order: BrowseSortOrder) -> [String] {
        paths.sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (ra?, rb?):
                return order == .oldestFirst ? ra < rb : ra > rb
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a < b
            }
        }
    }

    /// "October", in the grouping calendar and the given locale.
    static func monthTitle(_ month: BrowseMonth, calendar: Calendar, locale: Locale) -> String {
        month.start.formatted(monthStyle(calendar: calendar, locale: locale).month(.wide))
    }

    /// "October 2026".
    static func fullMonthTitle(_ month: BrowseMonth, calendar: Calendar, locale: Locale) -> String {
        month.start.formatted(monthStyle(calendar: calendar, locale: locale).month(.wide).year(.defaultDigits))
    }

    /// "2026". Built with `String(year)`, so there's never a grouping separator.
    static func yearTitle(_ year: Int) -> String {
        String(year)
    }

    /// A date style in the grouping calendar's zone, so the titles name the month the grouping put the photo in.
    private static func monthStyle(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        var style = Date.FormatStyle(locale: locale, timeZone: calendar.timeZone)
        style.calendar = calendar
        return style
    }

    private static func dayID(_ start: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        func two(_ value: Int?) -> String {
            let number = value ?? 0
            return number < 10 ? "0\(number)" : "\(number)"
        }
        return "day:\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))"
    }

    private static func valid(year: Int, month: Int) -> (year: Int, month: Int)? {
        (1900...2100).contains(year) && (1...12).contains(month) ? (year, month) : nil
    }

    private static func isDigits(_ text: Substring, count: Int) -> Bool {
        text.count == count && text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}
