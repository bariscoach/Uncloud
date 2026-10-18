import CryptoKit
import Foundation

/// The "new photos" feature: what is new in the library since the last complete export, and the reminder
/// about it. Everything here is pure (no UI, no I/O) so the rules can be tested without a library or iCloud.

/// One destination, source and iCloud account: the scope a watermark and its count apply to.
struct NewPhotosContext: Equatable, Sendable {
    let destination: URL
    let source: LibrarySource
    /// The signed-in Apple ID, for iCloud. Nil for the Photos library.
    let appleID: String?

    /// A file name for this scope, kept in Application Support rather than on the drive. The volume's UUID and the
    /// path on that volume identify the destination, so a drive that mounts under another name keeps its watermark.
    /// The Apple ID enters only as the pseudonymous account label that sessions use.
    var storageKey: String {
        let values = try? destination.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        let volumeID = values?.volumeUUIDString ?? ""
        let path = destination.standardizedFileURL.path(percentEncoded: false)
        var relative = path
        if let volume = values?.volume?.standardizedFileURL.path(percentEncoded: false) {
            let prefix = volume.hasSuffix("/") ? volume : volume + "/"
            if path.hasPrefix(prefix) {
                relative = String(path.dropFirst(prefix.count))
            }
        }
        let account = appleID.map(ExportSession.accountHash(appleID:)) ?? ""
        let identity = "uncloud-new-photos-v1|\(source.rawValue)|\(account)|\(volumeID)|\(relative)"
        return SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The state at the end of the last complete export of everything. Stored per context, outside the drive.
struct NewPhotosWatermark: Codable, Equatable, Sendable {
    /// When the export finished.
    var exportedAt: Date
    /// The library's size then, when known.
    var libraryCount: Int?
    /// iCloud: the newest item then (rank 0 of the walk) and when it was added. Nil for the Photos library.
    var newestAssetID: String?
    var newestAddedDate: Date?
}

/// What is new since the watermark. `isAtLeast` means the count stopped at the walk's limit.
struct NewPhotosStatus: Equatable, Sendable {
    let count: Int
    let isAtLeast: Bool
    let since: Date
}

/// How the run that ended finished, as far as the watermark cares.
enum RunOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

enum NewPhotosWatermarkPolicy {
    /// A watermark is saved only when every item of an export of everything was processed. Cancelled, failed and
    /// partial runs (items that couldn't be copied) leave the old watermark, so their new photos still count.
    static func shouldRecord(outcome: RunOutcome, isEverything: Bool, failedCount: Int) -> Bool {
        outcome == .completed && isEverything && failedCount == 0
    }
}

enum NewPhotosCounter {
    /// Beyond this many new items the count says "5,000+", so a long walk never runs unbounded.
    static let iCloudWalkLimit = 5_000
    static let iCloudPageSize = 200

    /// The items added since the watermark, walking from the newest (rank 0). The walk stops at the watermark's
    /// newest item, or at the first item added no later than it. Without dates, the newest ID is the boundary.
    /// Returns `isAtLeast` when there are more new items than `limit`.
    static func countICloud(
        since watermark: NewPhotosWatermark,
        fetcher: any ICloudPageFetching,
        limit: Int = iCloudWalkLimit,
        pageSize: Int = iCloudPageSize
    ) async throws -> (count: Int, isAtLeast: Bool) {
        var count = 0
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetcher.assets(offset: offset, limit: pageSize)
            if page.isEmpty {
                return (count, false)
            }
            for asset in page {
                if isWatermark(asset, watermark) {
                    return (count, false)
                }
                // The item past the limit proves there are more than `limit` new ones.
                if count == limit {
                    return (count, true)
                }
                count += 1
            }
            offset += page.count
        }
    }

    /// Whether `asset` is where the last export stopped: the same item, or one added no later than the watermark.
    static func isWatermark(_ asset: ICloudAsset, _ watermark: NewPhotosWatermark) -> Bool {
        if let newestID = watermark.newestAssetID, asset.id == newestID {
            return true
        }
        if let added = asset.added, let mark = watermark.newestAddedDate {
            return added <= mark
        }
        return false
    }

    /// Photos library: the identifiers in the library now that the last export didn't have.
    static func countLibrary(current: Set<String>, exported: Set<String>) -> Int {
        current.subtracting(exported).count
    }
}

/// The primary button's title. `fallback` is the title the rest of the Library uses (for example, "Export All Photos").
enum NewPhotosTitle {
    static let exportNewPhotos = "Export New Photos"
    static let chooseFolder = "Choose Folder…"

    /// An interrupted or paused run keeps the fallback, which is the resume title, so resuming wins over new photos.
    static func primary(
        isPaused: Bool,
        hasInterruptedRun: Bool,
        needsFolder: Bool,
        isEverything: Bool,
        hasNewPhotosStatus: Bool,
        fallback: String
    ) -> String {
        if isPaused || hasInterruptedRun { return fallback }
        if needsFolder { return chooseFolder }
        if isEverything, hasNewPhotosStatus { return exportNewPhotos }
        return fallback
    }
}

/// The words for counts and dates in the new-photos status.
enum NewPhotosText {
    /// "1 new photo", "1,243 new photos", "5,000+ new photos".
    static func countPhrase(_ status: NewPhotosStatus) -> String {
        let number = status.count.formatted()
        let plus = status.isAtLeast ? "+" : ""
        return "\(number)\(plus) new \(status.count == 1 && !status.isAtLeast ? "photo" : "photos")"
    }

    /// "today", "yesterday", "3 days ago" for the last week, otherwise "17 Sep" (in the locale's order).
    /// The second value says whether the phrase is relative, which decides whether it takes "on" in front.
    static func dayPhrase(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> (text: String, isRelative: Bool) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0:
            return (date.formatted(.dateTime.day().month(.abbreviated).locale(locale)), false)
        case 0: return ("today", true)
        case 1: return ("yesterday", true)
        case 2...6: return ("\(days) days ago", true)
        default: return (date.formatted(.dateTime.day().month(.abbreviated).locale(locale)), false)
        }
    }

    /// "1,243 new photos since your last export on 17 Sep.", or "Up to date. Last export 17 Sep." with none new.
    static func statusLine(_ status: NewPhotosStatus, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = dayPhrase(status.since, now: now, calendar: calendar, locale: locale)
        let when = day.isRelative ? day.text : "on \(day.text)"
        if status.count == 0, !status.isAtLeast {
            return "Up to date. Last export \(day.text)."
        }
        return "\(sentenceCase(countPhrase(status))) since your last export \(when)."
    }

    private static func sentenceCase(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

enum NewPhotosReminderFrequency: String, CaseIterable, Sendable {
    case weekly
    case daily

    var interval: TimeInterval {
        switch self {
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

enum NewPhotosReminder {
    static let notificationIdentifier = "new-photos-reminder"
    static let title = "New photos to back up"

    struct Input: Sendable {
        var isEnabled: Bool
        var count: Int
        var isAtLeast: Bool
        /// The destination folder is there (the drive is connected).
        var destinationConnected: Bool
        /// Automatic backup is on, so a connected drive is backed up on its own.
        var automaticBackupOn: Bool
        /// The iCloud session needs signing in again. A background check never prompts, so it skips.
        var signInNeeded: Bool
        var frequency: NewPhotosReminderFrequency
        var lastReminder: Date?
        var now: Date
    }

    /// Why a reminder isn't posted. Only counts are ever logged, so these are for tests and the log's wording.
    enum Skip: Equatable, Sendable {
        case disabled
        case nothingNew
        case signInNeeded
        case backUpAutomatically
        case recentlyReminded
    }

    enum Decision: Equatable, Sendable {
        case skip(Skip)
        case remind(body: String)
    }

    static func decide(_ input: Input) -> Decision {
        guard input.isEnabled else { return .skip(.disabled) }
        guard input.count > 0 || input.isAtLeast else { return .skip(.nothingNew) }
        if input.signInNeeded { return .skip(.signInNeeded) }
        if input.destinationConnected, input.automaticBackupOn { return .skip(.backUpAutomatically) }
        if let last = input.lastReminder, input.now.timeIntervalSince(last) < input.frequency.interval {
            return .skip(.recentlyReminded)
        }
        return .remind(body: body(count: input.count, isAtLeast: input.isAtLeast, connected: input.destinationConnected))
    }

    /// "1,243 new photos since your last export. Connect your backup drive to save them." When the drive is connected
    /// (and automatic backup is off), the body says to open Uncloud instead.
    static func body(count: Int, isAtLeast: Bool, connected: Bool) -> String {
        let status = NewPhotosStatus(count: count, isAtLeast: isAtLeast, since: .distantPast)
        let photos = NewPhotosText.countPhrase(status)
        let next = connected ? "Open Uncloud to back them up." : "Connect your backup drive to save them."
        return "\(photos.prefix(1).uppercased() + photos.dropFirst()) since your last export. \(next)"
    }
}
