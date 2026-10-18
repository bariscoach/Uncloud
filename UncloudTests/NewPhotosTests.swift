import Foundation
import Testing
@testable import Uncloud

@Suite("NewPhotos")
struct NewPhotosTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let britain = Locale(identifier: "en_GB")

    /// Items newest first, like the bridge's walk. Item `n` ranks `n`th from the newest and was added `count - n`
    /// minutes after `base`, so later ranks were added earlier.
    private static func library(_ count: Int, withDates: Bool = true) -> [ICloudAsset] {
        (0..<count).map { rank in
            ICloudAsset(
                id: "item-\(rank)",
                filename: "IMG_\(rank).HEIC",
                created: nil,
                isVideo: false,
                thumbnailURL: nil,
                added: withDates ? base.addingTimeInterval(TimeInterval((count - rank) * 60)) : nil
            )
        }
    }

    private static func watermark(newestID: String?, newestAdded: Date?) -> NewPhotosWatermark {
        NewPhotosWatermark(exportedAt: base, libraryCount: nil, newestAssetID: newestID, newestAddedDate: newestAdded)
    }

    private static func status(_ count: Int, atLeast: Bool = false, since: Date = base) -> NewPhotosStatus {
        NewPhotosStatus(count: count, isAtLeast: atLeast, since: since)
    }

    // MARK: - Watermark policy

    @Test func watermarkIsSavedOnlyAfterCompleteExportOfEverything() {
        #expect(NewPhotosWatermarkPolicy.shouldRecord(outcome: .completed, isEverything: true, failedCount: 0))
        #expect(!NewPhotosWatermarkPolicy.shouldRecord(outcome: .cancelled, isEverything: true, failedCount: 0))
        #expect(!NewPhotosWatermarkPolicy.shouldRecord(outcome: .failed, isEverything: true, failedCount: 0))
        #expect(!NewPhotosWatermarkPolicy.shouldRecord(outcome: .completed, isEverything: false, failedCount: 0))
        #expect(!NewPhotosWatermarkPolicy.shouldRecord(outcome: .completed, isEverything: true, failedCount: 2))
    }

    // MARK: - iCloud counting

    @Test func countStopsAtTheWatermarksNewestItem() async throws {
        let items = Self.library(10)
        // Item 3 was the newest when the last export finished, so items 0, 1 and 2 are new.
        let mark = Self.watermark(newestID: "item-3", newestAdded: items[3].added)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items))
        #expect(result.count == 3)
        #expect(!result.isAtLeast)
    }

    @Test func countStopsAtAnItemAddedNoLaterThanTheWatermark() async throws {
        let items = Self.library(10)
        // The newest item at the last export has since been deleted, so its ID is gone. The added date still marks the edge.
        let mark = Self.watermark(newestID: "deleted-item", newestAdded: items[2].added)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items))
        #expect(result.count == 2)
        #expect(!result.isAtLeast)
    }

    @Test func nothingNewWhenTheNewestItemIsStillFirst() async throws {
        let items = Self.library(5)
        let mark = Self.watermark(newestID: "item-0", newestAdded: items[0].added)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items))
        #expect(result.count == 0)
        #expect(!result.isAtLeast)
    }

    @Test func countWalksPagesAcrossTheBoundary() async throws {
        let items = Self.library(25)
        let mark = Self.watermark(newestID: "item-11", newestAdded: items[11].added)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items), pageSize: 4)
        #expect(result.count == 11)
        #expect(!result.isAtLeast)
    }

    @Test func countStopsAtTheLimitAndSaysAtLeast() async throws {
        let items = Self.library(40)
        let mark = Self.watermark(newestID: "item-30", newestAdded: items[30].added)
        // 30 new items against a limit of 5: the count stops at 5, and says there are more.
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items), limit: 5, pageSize: 3)
        #expect(result.count == 5)
        #expect(result.isAtLeast)
    }

    @Test func exactlyTheLimitIsNotAtLeast() async throws {
        let items = Self.library(12)
        let mark = Self.watermark(newestID: "item-5", newestAdded: items[5].added)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items), limit: 5)
        #expect(result.count == 5)
        #expect(!result.isAtLeast)
    }

    @Test func withoutDatesTheNewestIDIsTheBoundary() async throws {
        let items = Self.library(8, withDates: false)
        let mark = Self.watermark(newestID: "item-4", newestAdded: nil)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items))
        #expect(result.count == 4)
        #expect(!result.isAtLeast)
    }

    @Test func withoutDatesAndWithoutTheIDTheWalkCountsToTheLimit() async throws {
        let items = Self.library(8, withDates: false)
        let mark = Self.watermark(newestID: "gone", newestAdded: nil)
        let result = try await NewPhotosCounter.countICloud(since: mark, fetcher: FakeWalk(items: items), limit: 6)
        #expect(result.count == 6)
        #expect(result.isAtLeast)
    }

    @Test func libraryCountIsSetDifference() {
        let current: Set<String> = ["a", "b", "c", "d"]
        let exported: Set<String> = ["a", "b", "gone"]
        #expect(NewPhotosCounter.countLibrary(current: current, exported: exported) == 2)
        #expect(NewPhotosCounter.countLibrary(current: current, exported: current) == 0)
    }

    // MARK: - Titles

    @Test func primaryTitlePrecedence() {
        let fallback = "Export All Photos"
        func title(
            paused: Bool = false,
            interrupted: Bool = false,
            folder: Bool = true,
            everything: Bool = true,
            status: Bool = true,
            fallback: String = fallback
        ) -> String {
            NewPhotosTitle.primary(
                isPaused: paused,
                hasInterruptedRun: interrupted,
                needsFolder: !folder,
                isEverything: everything,
                hasNewPhotosStatus: status,
                fallback: fallback
            )
        }
        // Paused keeps the fallback, which is Resume.
        #expect(title(paused: true, fallback: "Resume") == "Resume")
        // An interrupted run keeps the fallback too, so resuming wins.
        #expect(title(interrupted: true, fallback: "Resume Export") == "Resume Export")
        // No folder beats new photos.
        #expect(title(folder: false) == "Choose Folder…")
        // New photos apply to everything only.
        #expect(title() == "Export New Photos")
        #expect(title(everything: false, fallback: "Export 3 Items") == "Export 3 Items")
        // No complete export yet: the default.
        #expect(title(status: false) == fallback)
    }

    // MARK: - Text

    @Test func countPhraseUsesSingularPluralAndPlus() {
        #expect(NewPhotosText.countPhrase(Self.status(1)) == "1 new photo")
        #expect(NewPhotosText.countPhrase(Self.status(1_243)) == "1,243 new photos")
        #expect(NewPhotosText.countPhrase(Self.status(5_000, atLeast: true)) == "5,000+ new photos")
    }

    @Test func dayPhraseIsRelativeForARecentWeek() {
        let now = Self.base
        #expect(NewPhotosText.dayPhrase(now, now: now, calendar: Self.utc).text == "today")
        #expect(NewPhotosText.dayPhrase(now.addingTimeInterval(-86_400), now: now, calendar: Self.utc).text == "yesterday")
        let threeDays = NewPhotosText.dayPhrase(now.addingTimeInterval(-3 * 86_400), now: now, calendar: Self.utc)
        #expect(threeDays.text == "3 days ago")
        #expect(threeDays.isRelative)
        let older = NewPhotosText.dayPhrase(now.addingTimeInterval(-30 * 86_400), now: now, calendar: Self.utc, locale: Self.britain)
        #expect(!older.isRelative)
        #expect(older.text == "15 Oct")
    }

    @Test func statusLineForNewAndUpToDate() {
        let since = Self.base.addingTimeInterval(-3 * 86_400)
        let newLine = NewPhotosText.statusLine(Self.status(1_243, since: since), now: Self.base, calendar: Self.utc)
        #expect(newLine == "1,243 new photos since your last export 3 days ago.")
        let upToDate = NewPhotosText.statusLine(Self.status(0, since: since), now: Self.base, calendar: Self.utc)
        #expect(upToDate == "Up to date. Last export 3 days ago.")
        let plus = NewPhotosText.statusLine(Self.status(5_000, atLeast: true, since: since), now: Self.base, calendar: Self.utc)
        #expect(plus == "5,000+ new photos since your last export 3 days ago.")
    }

    // MARK: - Reminder

    private static func input(
        count: Int = 1_243,
        connected: Bool = false,
        automatic: Bool = false,
        signInNeeded: Bool = false,
        enabled: Bool = true,
        frequency: NewPhotosReminderFrequency = .weekly,
        lastReminder: Date? = nil
    ) -> NewPhotosReminder.Input {
        NewPhotosReminder.Input(
            isEnabled: enabled,
            count: count,
            isAtLeast: false,
            destinationConnected: connected,
            automaticBackupOn: automatic,
            signInNeeded: signInNeeded,
            frequency: frequency,
            lastReminder: lastReminder,
            now: base
        )
    }

    @Test func reminderWhenDriveIsNotConnected() {
        let decision = NewPhotosReminder.decide(Self.input())
        #expect(decision == .remind(body: "1,243 new photos since your last export. Connect your backup drive to save them."))
    }

    @Test func reminderWhenConnectedWithAutomaticBackupOffSaysToOpenUncloud() {
        let decision = NewPhotosReminder.decide(Self.input(connected: true, automatic: false))
        #expect(decision == .remind(body: "1,243 new photos since your last export. Open Uncloud to back them up."))
    }

    @Test func connectedWithAutomaticBackupOnJustBacksUp() {
        #expect(NewPhotosReminder.decide(Self.input(connected: true, automatic: true)) == .skip(.backUpAutomatically))
    }

    @Test func reminderSkipsWhenDisabledOrNothingNew() {
        #expect(NewPhotosReminder.decide(Self.input(enabled: false)) == .skip(.disabled))
        #expect(NewPhotosReminder.decide(Self.input(count: 0)) == .skip(.nothingNew))
    }

    @Test func reminderSkipsSilentlyWhenSignInIsNeeded() {
        #expect(NewPhotosReminder.decide(Self.input(signInNeeded: true)) == .skip(.signInNeeded))
    }

    @Test func reminderWaitsOneFrequencyBetweenPosts() {
        let weekAgo = Self.base.addingTimeInterval(-7 * 86_400)
        #expect(NewPhotosReminder.decide(Self.input(frequency: .weekly, lastReminder: Self.base.addingTimeInterval(-86_400))) == .skip(.recentlyReminded))
        #expect(NewPhotosReminder.decide(Self.input(frequency: .weekly, lastReminder: weekAgo)).isReminder)
        #expect(NewPhotosReminder.decide(Self.input(frequency: .daily, lastReminder: Self.base.addingTimeInterval(-86_400))).isReminder)
        #expect(NewPhotosReminder.decide(Self.input(frequency: .daily, lastReminder: Self.base.addingTimeInterval(-3_600))) == .skip(.recentlyReminded))
    }

    // MARK: - Store and scope

    @Test func storeRoundTripsWatermarkAndLibraryIDs() throws {
        try withTemporaryDirectory { folder in
            let store = NewPhotosStore(directory: folder.appending(path: "store", directoryHint: .isDirectory))
            let context = NewPhotosContext(destination: folder, source: .photosLibrary, appleID: nil)
            #expect(store.watermark(for: context) == nil)
            let mark = Self.watermark(newestID: "item-0", newestAdded: Self.base)
            try store.save(mark, for: context)
            #expect(store.watermark(for: context) == mark)
            try store.saveLibraryIDs(["b", "a"], for: context)
            #expect(store.libraryIDs(for: context) == ["a", "b"])
            store.remove(for: context)
            #expect(store.watermark(for: context) == nil)
            #expect(store.libraryIDs(for: context) == nil)
        }
    }

    @Test func storageKeyDependsOnSourceAccountAndFolder() {
        let folder = URL(fileURLWithPath: "/Volumes/Backup/Photos", isDirectory: true)
        let photos = NewPhotosContext(destination: folder, source: .photosLibrary, appleID: nil)
        let iCloud = NewPhotosContext(destination: folder, source: .iCloud, appleID: "someone@example.com")
        let otherAccount = NewPhotosContext(destination: folder, source: .iCloud, appleID: "other@example.com")
        let otherFolder = NewPhotosContext(destination: folder.appending(path: "2", directoryHint: .isDirectory), source: .photosLibrary, appleID: nil)
        #expect(photos.storageKey == photos.storageKey)
        #expect(Set([photos.storageKey, iCloud.storageKey, otherAccount.storageKey, otherFolder.storageKey]).count == 4)
        // The Apple ID itself never appears in the file name.
        #expect(!iCloud.storageKey.contains("someone"))
    }
}

/// A library walk for tests: items newest first, served by offset like the bridge's page command.
private struct FakeWalk: ICloudPageFetching {
    let items: [ICloudAsset]

    func count() async throws -> Int {
        items.count
    }

    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
        guard offset < items.count else { return [] }
        return Array(items[offset..<min(items.count, offset + limit)])
    }
}

private extension NewPhotosReminder.Decision {
    var isReminder: Bool {
        if case .remind = self { return true }
        return false
    }
}
