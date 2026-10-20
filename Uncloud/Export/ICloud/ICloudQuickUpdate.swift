import Foundation

/// The quick update for whole-library iCloud exports: new photos only, for routine runs.
///
/// New photos are inserted at rank 0 (icloudpd's newest-first order), so a quick update scans from the top and
/// collects the items that aren't on the drive yet, stopping after a long run of items that are. It never walks
/// the rest of the library, so it doesn't prove that nothing changed further down. That's what the full check is
/// for: a run that goes through every rank (`ICloudResumePlanner`) about once a month, or on demand. A quick
/// update never writes the resume point, so the full check's `lastFullWalkAt` and anchor stay as they were.
///
/// Pure apart from `fetch`, the bridge's `page` request, so tests can drive it with a list.
enum ICloudQuickUpdate {
    enum Plan: Equatable, Sendable {
        /// Items not on the drive at the top of the library, by ID with their ranks (possibly empty).
        case only([String: Int])
        /// A full check is needed; the reason is shown in the activity list.
        case fullCheck(reason: String)
    }

    static let reasonDue = "It’s been a while since Uncloud checked your whole library, so it’s checking all of it now. Photos already in your backup are skipped."
    static let reasonTooMany = "Too many photos to look for quickly, so Uncloud is checking your whole library. Photos already in your backup are skipped."

    /// Whether a quick update may run at all. False means a full check.
    static func isEligible(
        point: ICloudResumePoint?,
        account: String,
        layout: FolderLayout,
        known: Set<String>,
        missing: Set<String>,
        now: Date,
        maxAge: TimeInterval = ICloudResumeSettings().fullCheckInterval
    ) -> Bool {
        guard !known.isEmpty, missing.isEmpty, let point, point.account == account, point.layout == layout.rawValue,
              let lastFullWalkAt = point.lastFullWalkAt else {
            return false
        }
        // A last full walk in the future (the clock changed) doesn't count as recent.
        let age = now.timeIntervalSince(lastFullWalkAt)
        return age >= 0 && age <= maxAge
    }

    /// Scans from the top of the library for items not in `known`, stopping after `settings.overlap` known items
    /// in a row. Ends with `.fullCheck` when there are more new items than `settings.quickMaxItems`, or when the
    /// scan reaches `settings.quickScanLimit` ranks without finding that run.
    static func plan(
        libraryCount: Int,
        known: Set<String>,
        settings: ICloudResumeSettings,
        fetch: ICloudResumePlanner.Fetch
    ) async throws -> Plan {
        var only: [String: Int] = [:]
        var knownRun = 0
        var rank = 0
        while rank < libraryCount {
            guard rank < settings.quickScanLimit else { break }
            try Task.checkCancellation()
            let limit = min(settings.pageSize, libraryCount - rank, settings.quickScanLimit - rank)
            let page = try await fetch(rank, limit)
            for id in page {
                if known.contains(id) {
                    knownRun += 1
                } else {
                    only[id] = rank
                    knownRun = 0
                }
                rank += 1
                if knownRun >= settings.overlap {
                    return only.count > settings.quickMaxItems ? .fullCheck(reason: reasonTooMany) : .only(only)
                }
            }
            if only.count > settings.quickMaxItems {
                return .fullCheck(reason: reasonTooMany)
            }
            // The library ended early (it shrank meanwhile).
            if page.count < limit {
                return .only(only)
            }
        }
        // The top of the library ended, or the scan limit did, without a long run of known items.
        return rank >= libraryCount ? .only(only) : .fullCheck(reason: reasonTooMany)
    }
}
