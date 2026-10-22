import Foundation

/// Where a whole-library iCloud export (month or flat layout) continues: `.photo-export/resume-<layout>.json`,
/// one file per layout (plan 3.2, re-derived for icloudpd's NEWEST-FIRST order). A point saved before the files were
/// per layout lives in `resume.json`; it's read only while its `layout` is the one asked for.
///
/// Rank 0 is the newest item, and a photo added to iCloud is inserted at rank 0, shifting every other rank by
/// one. The point says: when it was saved, the library had `libraryCount` items, the item at rank `anchor.rank`
/// was `anchor.id`, and the walk had been through every rank above it (`0..<coveredThrough`, possibly over
/// several runs).
///
/// The point is only ever a place to continue the walk from, never proof that the part above it is still
/// complete: photos can be added, removed, hidden or re-dated anywhere above the anchor between runs, and no
/// count iCloud offers can tell "nothing changed" from "one removed and one added" in that part. So a run that
/// continues from the anchor always ends with a closing walk from rank 0 back down to the anchor (see
/// `ICloudContinuationPlan.fromRank`).
struct ICloudResumePoint: Codable, Equatable, Sendable {
    struct Anchor: Codable, Equatable, Sendable {
        var id: String
        var rank: Int
    }

    var schema = 1
    /// `ExportSession.accountHash`, never the Apple ID.
    var account: String
    /// `FolderLayout` raw value; another layout's point is ignored.
    var layout: String
    var libraryCount: Int
    /// R: the walk has been through ranks `0..<R`. The anchor is the item at rank R − 1.
    var coveredThrough: Int
    var anchor: Anchor
    /// When the last run that went through every rank of the library started. For information only: nothing
    /// waits for a periodic full walk, because every run that reaches the end of the library is one.
    var lastFullWalkAt: Date?
    var updatedAt: Date
    /// The library's count beyond the items the walk can list, from the last complete walk with nothing failed:
    /// iCloud counts them, but they never come up in a listing, so they can't be exported. Nil when unknown (a
    /// point from before this was kept, or no complete walk yet). "To go" leaves them out.
    var unlistedCount: Int?

    /// The file before points were kept per layout. Read as a fallback, never written.
    static let legacyFileName = "resume.json"

    static func fileName(forLayout layout: String) -> String {
        "resume-\(layout).json"
    }

    /// Whether `name` is a resume point file, the per-layout kind or the legacy one.
    static func isResumeFileName(_ name: String) -> Bool {
        name == legacyFileName || (name.hasPrefix("resume-") && name.hasSuffix(".json"))
    }

    static func url(in destination: URL, layout: FolderLayout) -> URL {
        url(in: destination, layoutName: layout.rawValue)
    }

    private static func url(in destination: URL, layoutName: String) -> URL {
        folder(in: destination).appending(path: fileName(forLayout: layoutName))
    }

    private static func legacyURL(in destination: URL) -> URL {
        folder(in: destination).appending(path: legacyFileName)
    }

    private static func folder(in destination: URL) -> URL {
        destination.appending(path: ".photo-export", directoryHint: .isDirectory)
    }

    /// The point for `layout`, or nil when there's none or it can't be read (a newer schema, or a file that
    /// was emptied or marked invalid, included). No point means a walk from rank 0. Reads the layout's own file
    /// first, then the legacy `resume.json`, but only when that one is for this layout too: another layout's
    /// point is never used.
    static func load(in destination: URL, layout: FolderLayout) -> ICloudResumePoint? {
        if let point = read(url(in: destination, layout: layout)), point.layout == layout.rawValue {
            return point
        }
        if let legacy = read(legacyURL(in: destination)), legacy.layout == layout.rawValue {
            return legacy
        }
        return nil
    }

    private static func read(_ url: URL) -> ICloudResumePoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Whole seconds (points saved before fractions were kept) and fractions both read.
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            return try Date.ISO8601FormatStyle().parse(text)
        }
        guard let point = try? decoder.decode(ICloudResumePoint.self, from: data), point.schema == 1 else { return nil }
        return point
    }

    /// Writes the point atomically, to its own layout's file only, and removes the legacy `resume.json` when that
    /// file was this layout's (it's superseded now). Errors are the caller's to ignore: a missing point costs a full
    /// walk, never data.
    func save(in destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // With fractions: a whole-second time would make two walks in the same second look the same.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        let url = Self.url(in: destination, layoutName: layout)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        let legacy = Self.legacyURL(in: destination)
        if let legacyPoint = Self.read(legacy), legacyPoint.layout == layout {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// Removes the point of `layout`, and the legacy file when it's that layout's.
    static func remove(in destination: URL, layout: FolderLayout) {
        try? FileManager.default.removeItem(at: url(in: destination, layout: layout))
        if let legacy = read(legacyURL(in: destination)), legacy.layout == layout.rawValue {
            try? FileManager.default.removeItem(at: legacyURL(in: destination))
        }
    }
}

/// The resume logic's limits. Tests shrink them.
struct ICloudResumeSettings: Sendable, Equatable {
    /// Below this R a full walk is cheap enough; no point in continuing from a rank.
    var minimumCovered = 500
    /// How far from where it should be the anchor is looked for, in both directions.
    var searchWindow = 200
    /// The scan for new items at the top stops after this many items in a row already on the drive.
    var overlap = 200
    /// How far past the expected number of new items the top of the library is scanned for them.
    var topScanSlack = 2_000
    /// Page size of the bridge's `page` requests.
    var pageSize = 100
    /// More items than this fraction of the library to fetch one by one: walking is cheaper.
    var maxSelectiveFraction = 0.3
    /// How long after a full walk a quick update may stand in for one (see `ICloudQuickUpdate`).
    var fullCheckInterval: TimeInterval = 30 * 24 * 60 * 60
    /// How many ranks from the top a quick update scans for new items before it gives up.
    var quickScanLimit = 5_000
    /// More new items than this for a quick update means a full check instead.
    var quickMaxItems = 2_000
}

/// How a whole-library bridge export proceeds.
enum ICloudContinuationPlan: Equatable, Sendable {
    /// Walk everything from rank 0 (items on the drive are passed over without a file check).
    /// `reason` is set when a continuation was possible in principle but couldn't be used.
    case fullWalk(reason: String?)
    /// 1. Download `only` (items not on the drive found at the top of the library, newest first), by ID.
    /// 2. Walk from `anchorRank + 1` to the end.
    /// 3. Once that walk has reached the end, the closing walk: from rank 0 until the anchor, so every rank
    ///    above it is visited again in this run.
    case fromRank(FromRank)

    struct FromRank: Equatable, Sendable {
        var anchorID: String
        /// The anchor's rank now.
        var anchorRank: Int
        /// Items to fetch by ID before the walk, with their current ranks.
        var only: [String: Int]
        /// Of `only`, how many are new (not files the drive check found missing).
        var newItems: Int
        var startRank: Int { anchorRank + 1 }
    }

    static let reasonAnchorMoved = "The last exported photo moved in your library"
    static let reasonTooManyChanges = "Too many photos changed since the last export"
}

/// Decides between continuing from the resume point and walking everything. Pure apart from `fetch`, the
/// bridge's `page` request, so tests can drive it with a list.
///
/// SAFETY INVARIANT (what makes skipping impossible): a run never trusts the part of the library above the
/// anchor. A `.fromRank` run visits ranks `anchorRank + 1 ..< end` in its walk and ranks `0 ..< anchorRank` in
/// its closing walk, so a run that gets to the end of both has visited every rank of the library as it was
/// during the run, exactly like a walk from rank 0, whatever was added, removed, hidden or re-dated between
/// runs. A run that stops early (a throttle, a cancel) never claims more than the walk from the anchor covered;
/// the next run continues from there and does the closing walk itself. The top scan below only decides which
/// new items are downloaded first; nothing depends on it finding them all.
enum ICloudResumePlanner {
    typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> [String]

    struct Input: Sendable {
        var point: ICloudResumePoint?
        var account: String
        var layout: FolderLayout
        var now: Date
        /// The library's size now.
        var libraryCount: Int
        /// Items on the drive in this layout, by asset ID.
        var known: Set<String>
        /// Items the drive check just found missing or damaged (forgotten, so not in `known`). Only used to
        /// tell new items from missing ones in the count of new items.
        var missing: Set<String> = []
        var settings: ICloudResumeSettings
    }

    static func plan(_ input: Input, fetch: Fetch) async throws -> ICloudContinuationPlan {
        let settings = input.settings
        guard let point = input.point, point.account == input.account, point.layout == input.layout.rawValue,
              point.coveredThrough >= settings.minimumCovered, point.anchor.rank == point.coveredThrough - 1,
              input.libraryCount > 0 else {
            return .fullWalk(reason: nil)
        }

        var ids: [Int: String] = [:]
        func load(_ range: Range<Int>) async throws {
            var start = range.lowerBound
            while start < range.upperBound {
                try Task.checkCancellation()
                if ids[start] != nil {
                    start += 1
                    continue
                }
                let limit = min(settings.pageSize, range.upperBound - start)
                let page = try await fetch(start, limit)
                for (offset, id) in page.enumerated() {
                    ids[start + offset] = id
                }
                if page.count < limit {
                    // The library ended early (it shrank meanwhile).
                    return
                }
                start += limit
            }
        }

        // 1. Find the anchor near where it should be now. New items push it down; deletions pull it up.
        //    Where it's found doesn't matter for safety (the closing walk covers everything above it), only
        //    for how much of the library is walked twice.
        let n = input.libraryCount
        let expected = (point.coveredThrough - 1) + (n - point.libraryCount)
        let low = max(0, expected - settings.searchWindow)
        let high = min(n, expected + settings.searchWindow + 1)
        guard low < high else { return .fullWalk(reason: ICloudContinuationPlan.reasonAnchorMoved) }
        try await load(low..<high)
        guard let anchorRank = (low..<high).first(where: { ids[$0] == point.anchor.id }) else {
            return .fullWalk(reason: ICloudContinuationPlan.reasonAnchorMoved)
        }

        // 2. New photos are at the top: fetch what isn't on the drive there first, until a long run of items
        //    already on the drive. Best effort; the closing walk finds anything this misses.
        let shift = anchorRank - (point.coveredThrough - 1)
        let scanEnd = min(anchorRank, max(0, shift) + settings.overlap + settings.topScanSlack)
        var only: [String: Int] = [:]
        var knownRun = 0
        var rank = 0
        while rank < scanEnd {
            if ids[rank] == nil {
                try await load(rank..<min(scanEnd, rank + settings.pageSize))
            }
            guard let id = ids[rank] else { break }
            if input.known.contains(id) {
                knownRun += 1
            } else {
                only[id] = rank
                knownRun = 0
            }
            rank += 1
            if only.count >= shift && knownRun >= settings.overlap {
                break
            }
        }
        if Double(only.count) > Double(n) * settings.maxSelectiveFraction {
            return .fullWalk(reason: ICloudContinuationPlan.reasonTooManyChanges)
        }
        let newItems = only.keys.count { !input.missing.contains($0) }
        return .fromRank(.init(anchorID: point.anchor.id, anchorRank: anchorRank, only: only, newItems: newItems))
    }
}

/// Follows how far a whole-library bridge export's walk has got, to save the next resume point.
///
/// R grows with each finished walk item, in rank order. Items on the drive are passed over without an event,
/// so the anchor is the last item with an event. The first failure (a half-done Live Photo included) freezes R
/// for the rest of the run, so it's never jumped over: the next run's walk starts at the failed item. Items
/// downloaded by ID before the walk, and the closing walk's items, never move R; they're above the anchor.
struct ICloudCoverage: Sendable {
    private(set) var libraryCount: Int
    /// The anchor before the walk: the verified resume anchor, or nil for a walk from rank 0.
    let base: ICloudResumePoint.Anchor?
    private(set) var last: ICloudResumePoint.Anchor?
    private(set) var isFrozen = false
    /// Set when the walk reached the end of the library with nothing failed: the item at the last rank.
    private(set) var end: ICloudResumePoint.Anchor?

    init(libraryCount: Int, base: ICloudResumePoint.Anchor?) {
        self.libraryCount = libraryCount
        self.base = base
    }

    /// A walk item finished (downloaded or found on the drive).
    mutating func finished(asset: String, rank: Int?) {
        guard !isFrozen else { return }
        guard let rank else {
            // A bridge too old to say where it is: nothing past here can be trusted.
            isFrozen = true
            return
        }
        if let current = last ?? base, rank <= current.rank { return }
        last = .init(id: asset, rank: rank)
    }

    /// The walk reached the end of the library with nothing failed; `anchor` is the item at the last rank now.
    mutating func reachedEnd(anchor: ICloudResumePoint.Anchor, libraryCount: Int) {
        guard !isFrozen else { return }
        end = anchor
        self.libraryCount = libraryCount
    }

    /// A walk item failed or was left half done.
    mutating func failed() {
        isFrozen = true
    }

    /// The point to save now, or nil when this run has nothing to say (keep the old one). `visitedEverything`
    /// is when this run started, once it has visited every rank of the library (its walk and closing walk).
    func point(account: String, layout: FolderLayout, previous: ICloudResumePoint?, visitedEverything: Date?,
               unlistedCount: Int? = nil, now: Date) -> ICloudResumePoint? {
        guard let anchor = end ?? last ?? base, anchor.rank >= 0 else { return nil }
        return ICloudResumePoint(
            account: account,
            layout: layout.rawValue,
            libraryCount: max(libraryCount, anchor.rank + 1),
            coveredThrough: anchor.rank + 1,
            anchor: anchor,
            lastFullWalkAt: visitedEverything ?? previous?.lastFullWalkAt,
            updatedAt: now,
            unlistedCount: unlistedCount
        )
    }
}
