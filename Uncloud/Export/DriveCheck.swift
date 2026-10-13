import Foundation

/// The paths icloudpd writes, shared by the checksum scanner and the drive check, so both agree on which
/// files in a destination are downloads and which are the user's own.
enum ICloudDownloadPaths {
    /// `YYYY/MM/name`: icloudpd's `--folder-structure {:%Y/%m}`, the month layout.
    static func isMonthPath(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0].count == 4 && parts[0].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[1].count == 2 && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
            && !parts[2].isEmpty
    }

    /// `Album/name`: one icloudpd run per album, each with `--folder-structure none` into the album's folder.
    static func isAlbumPath(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Whether an unrecorded file at `relativePath` is one icloudpd wrote for an export in `layout`: month
    /// folders in the month and album layouts, album folders in the album layout. Never in the flat layout,
    /// where the user's own files sit next to the downloads and only reported paths are recorded (plan 7c).
    static func isDownloadPath(_ relativePath: String, layout: FolderLayout) -> Bool {
        switch layout {
        case .flat:
            false
        case .album:
            isMonthPath(relativePath) || isAlbumPath(relativePath)
        case .month, .place, .placeThenMonth:
            isMonthPath(relativePath)
        }
    }
}

/// Counts iCloud items from manifest records. Items recorded by asset ID (`icloud-id:`) are exact. Items
/// recorded only by path (`icloud:`, from icloudpd runs and older versions) are grouped from their files:
/// XMP sidecars don't count, and neither does a Live Photo's movie next to its photo (same name, `.MOV`).
enum ICloudItemCount {
    struct Count: Equatable, Sendable {
        /// Items recorded by asset ID, in the selection.
        var exact: Int
        /// Items grouped from path-only records whose files no ID record lists.
        var grouped: Int
        /// True when `grouped` contributes, so the total is "about".
        var isApproximate: Bool { grouped > 0 }
        var total: Int { exact + grouped }
    }

    /// - Parameters:
    ///   - records: Manifest records, key to relative paths (`ExportManifest.records(in:)`).
    ///   - selection: Only items it contains count. Path-only records have no ID: they count for `allExcept`
    ///     selections (approximately), and not at all for `only`.
    static func count(records: [String: [String]], selection: LibrarySelection = .everything) -> Count {
        var exact = 0
        var idPaths: Set<String> = []
        var supersededPartials: Set<String> = []
        for (key, paths) in records where key.hasPrefix(ExportManifest.iCloudIDPrefix) {
            let asset = String(key.dropFirst(ExportManifest.iCloudIDPrefix.count))
            idPaths.formUnion(paths)
            supersededPartials.insert(asset)
            if selection.contains(asset) {
                exact += 1
            }
        }
        var legacyPaths: [String] = []
        for (key, paths) in records where key.hasPrefix(ExportManifest.iCloudPathPrefix) {
            legacyPaths.append(contentsOf: paths.filter { !idPaths.contains($0) })
        }
        let grouped: Int
        if case .only = selection {
            grouped = 0
        } else {
            grouped = groupedItemCount(paths: legacyPaths)
        }
        return Count(exact: exact, grouped: grouped)
    }

    /// The number of items a set of files makes: one per file, except XMP sidecars and Live Photo movies
    /// whose photo (same folder, same name) is in the set.
    static func groupedItemCount<S: Sequence>(paths: S) -> Int where S.Element == String {
        var stemsByFolder: [String: Set<String>] = [:]
        var movies: [(folder: String, stem: String)] = []
        var count = 0
        for path in Set(paths) {
            let (folder, name) = split(path)
            let ext = (name as NSString).pathExtension.lowercased()
            let stem = (name as NSString).deletingPathExtension.lowercased()
            switch ext {
            case "xmp":
                continue
            case "mov":
                movies.append((folder, stem))
            default:
                stemsByFolder[folder, default: []].insert(stem)
                count += 1
            }
        }
        for movie in movies where stemsByFolder[movie.folder]?.contains(movie.stem) != true {
            count += 1
        }
        return count
    }

    private static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}

/// What "Check the drive" found, after acting on it.
struct DriveCheckReport: Equatable, Sendable {
    var mode: DriveInventory.Mode
    /// Items in the current selection (0 when the library's size isn't known yet).
    var selectedCount: Int
    /// Selected items whose files are all on the drive.
    var onDrive: Int
    /// True when `onDrive` includes items counted from path-only records ("about 9,200").
    var isApproximate: Bool
    /// `selectedCount − onDrive`, at least 0.
    var toGo: Int
    /// Items with a recorded file that's gone. Forgotten, so they're exported again.
    var missingItems: Int
    var missingFiles: [String]
    /// Files that are empty, or whose size changed since the last check: truncated or damaged.
    var damagedFiles: [String]
    /// Damaged files moved into `.photo-export/set-aside/<folder>/` (never deleted); their items are forgotten.
    var setAsideFiles: [String]
    /// The set-aside folder name used for this check.
    var setAsideFolder: String
    /// Files at icloudpd's paths that no record listed, now recorded by path (size only, hashed later).
    var registeredFiles: [String]
    /// Other files no record lists, such as the user's own documents. Never recorded.
    var otherFiles: Int
    /// `.part`/`.partial` leftovers of interrupted downloads, plus items recorded as partly downloaded.
    var partialFiles: Int
    var partialItems: Int
    /// Files listed in this check.
    var filesListed: Int
    var seconds: Double

    /// The summary stored in the export session.
    var summary: ExportSession.DriveCheckSummary {
        ExportSession.DriveCheckSummary(
            onDrive: onDrive,
            toGo: toGo,
            missing: missingItems,
            damaged: damagedFiles.count,
            setAside: setAsideFiles.count,
            untracked: registeredFiles.count + otherFiles,
            mode: mode == .full ? .full : .quick,
            seconds: seconds
        )
    }

    /// True when files were missing or damaged, so items will be exported again.
    var foundProblems: Bool {
        missingItems > 0 || !damagedFiles.isEmpty
    }
}

/// "Check the drive": compares what the manifest records with what's on the drive (a `DriveInventory`
/// listing, stat only), then acts on the differences (plan 2.3):
///
/// - **Missing**: a record with a file that's gone is forgotten, so the item is exported again.
/// - **Damaged / truncated**: a recorded file that's empty, or whose size differs from the last `files.tsv`, is
///   moved to `.photo-export/set-aside/<folder>/` (never deleted), and its item is forgotten. For iCloud this
///   matters: icloudpd would otherwise see "same name, different size" and save a second copy next to it.
/// - **Untracked, iCloud**: a file at an icloudpd path with no record is recorded as `icloud:<path>` by size
///   only. Its checksum is added later by the export's checksum scanner, never during the check.
/// - **Untracked, other**: counted as other files, never recorded.
/// - **Partial**: `.part` leftovers, and files of items recorded as only partly downloaded; neither counts as
///   on the drive.
///
/// Then it counts the current selection: already on this drive, and to go (plan 2.4).
enum DriveCheck {
    struct Input: Sendable {
        var destination: URL
        var source: LibrarySource
        var layout: FolderLayout
        var selection: LibrarySelection
        /// The selected item count, from the library's size; 0 when unknown.
        var selectedCount: Int
        /// Photos library only: every item's ID, to count only items still in the library. Nil to skip that.
        var libraryIDs: Set<String>?
        /// The folder name under `set-aside/` for damaged files, such as the session's ID.
        var setAsideFolder: String
        /// False for the automatic checks (a folder chosen, the app launched, a drive connected): those only
        /// report. Nothing on the drive changes unless the person started an export or chose Check Drive.
        var changesDrive = true
    }

    /// What the reconcile decided, before anything on the drive changes.
    struct Plan: Equatable, Sendable {
        /// Record keys to forget because a file is missing, with the missing files.
        var missing: [String: [String]] = [:]
        /// Record keys with a damaged file, with those files.
        var damaged: [String: [String]] = [:]
        /// Unrecorded files at icloudpd paths, to record by path.
        var register: [String] = []
        var otherFiles = 0
        var partialItems = 0
        var partialItemFiles = 0
    }

    /// Lists the drive (`mode`), reconciles it with the manifest, acts on the findings, writes the new
    /// `files.tsv` snapshot, and counts. Runs off the main actor; cancelling stops the listing (nothing on
    /// the drive has changed by then). Don't run it while an export writes to the destination.
    static func run(
        _ input: Input,
        mode: DriveInventory.Mode,
        progress: (@Sendable (DriveInventory.Progress) -> Void)? = nil
    ) async throws -> DriveCheckReport {
        let started = ContinuousClock.now
        let previous = ExportManifest.filesSnapshot(in: input.destination)
        let inventory = try await DriveInventory.run(
            destination: input.destination, mode: mode, previous: previous, progress: progress
        )
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            try apply(input, inventory: inventory, previous: previous, started: started)
        }.value
    }

    /// The reconcile rules, without touching the drive.
    static func plan(
        records: [String: [String]],
        inventory: [String: FilesSnapshot.FileEntry],
        previous: FilesSnapshot?,
        source: LibrarySource,
        layout: FolderLayout
    ) -> Plan {
        var plan = Plan()
        var recordedPaths: Set<String> = []
        var idAssets: Set<String> = []
        for key in records.keys where key.hasPrefix(ExportManifest.iCloudIDPrefix) {
            idAssets.insert(String(key.dropFirst(ExportManifest.iCloudIDPrefix.count)))
        }

        for (key, paths) in records {
            if key.hasPrefix(ExportManifest.iCloudPartialPrefix) {
                // Its files aren't untracked downloads; it isn't on the drive either, unless superseded.
                recordedPaths.formUnion(paths)
                let asset = String(key.dropFirst(ExportManifest.iCloudPartialPrefix.count))
                if !idAssets.contains(asset) {
                    plan.partialItems += 1
                    plan.partialItemFiles += paths.count { inventory[$0] != nil }
                }
                continue
            }
            recordedPaths.formUnion(paths)
            var missing: [String] = []
            var damaged: [String] = []
            for path in paths {
                guard let entry = inventory[path] else {
                    missing.append(path)
                    continue
                }
                if isDamaged(path: path, entry: entry, previous: previous?.files[path]) {
                    damaged.append(path)
                }
            }
            if !missing.isEmpty {
                plan.missing[key] = missing.sorted()
            }
            if !damaged.isEmpty {
                plan.damaged[key] = damaged.sorted()
            }
        }

        for path in inventory.keys where !recordedPaths.contains(path) {
            if source == .iCloud, ICloudDownloadPaths.isDownloadPath(path, layout: layout),
               ExportManifest.isSafeRelativePath(path) {
                plan.register.append(path)
            } else {
                plan.otherFiles += 1
            }
        }
        plan.register.sort()
        return plan
    }

    /// Empty, or a different size than at the last check. Sidecars are rewritten when an item's details
    /// change, so only an empty one counts.
    static func isDamaged(path: String, entry: FilesSnapshot.FileEntry, previous: FilesSnapshot.FileEntry?) -> Bool {
        if entry.size == 0 { return true }
        if (path as NSString).pathExtension.lowercased() == "xmp" { return false }
        guard let previous else { return false }
        return previous.size != entry.size
    }

    /// Already on this drive, for the selection, from the records left after the check.
    static func onDrive(
        records: [String: [String]],
        source: LibrarySource,
        selection: LibrarySelection,
        selectedCount: Int,
        libraryIDs: Set<String>?
    ) -> (count: Int, isApproximate: Bool) {
        var count: Int
        var isApproximate = false
        switch source {
        case .photosLibrary:
            let ids = records.keys.filter { !$0.hasPrefix(ExportManifest.iCloudPathPrefix) && !$0.hasPrefix("icloud-") }
            count = ids.count { selection.contains($0) && (libraryIDs?.contains($0) ?? true) }
        case .iCloud:
            let items = ICloudItemCount.count(records: records, selection: selection)
            count = items.total
            isApproximate = items.isApproximate
        }
        if selectedCount > 0 {
            count = min(count, selectedCount)
        }
        return (count, isApproximate)
    }

    // MARK: - Acting on the findings

    private static func apply(
        _ input: Input,
        inventory: DriveInventory.Result,
        previous: FilesSnapshot?,
        started: ContinuousClock.Instant
    ) throws -> DriveCheckReport {
        let destination = input.destination
        var records = ExportManifest.records(in: destination)
        let plan = plan(records: records, inventory: inventory.files, previous: previous,
                        source: input.source, layout: input.layout)
        guard input.changesDrive else {
            return report(input, inventory: inventory, plan: plan, records: records,
                          setAside: [], register: [], started: started)
        }

        // Damaged files are moved out of the way first; an item is forgotten only once its file has moved,
        // so a file that couldn't be moved is never downloaded a second time next to itself.
        var setAside: [String] = []
        var forgotten = Set(plan.missing.keys)
        if !plan.damaged.isEmpty {
            let paths = Array(Set(plan.damaged.values.flatMap { $0 })).sorted()
            let moved = (try? ExportManifest.setAside(paths: paths, session: input.setAsideFolder, in: destination)) ?? [:]
            setAside = moved.keys.sorted()
            for (key, files) in plan.damaged where files.allSatisfy({ moved[$0] != nil }) {
                forgotten.insert(key)
            }
        }
        // Partial records an ID record has superseded are dropped with the rest.
        for key in records.keys where key.hasPrefix(ExportManifest.iCloudPartialPrefix) {
            let asset = String(key.dropFirst(ExportManifest.iCloudPartialPrefix.count))
            if records[ExportManifest.iCloudIDPrefix + asset] != nil {
                forgotten.insert(key)
            }
        }
        if !forgotten.isEmpty {
            try ExportManifest.forget(forgotten, in: destination)
            for key in forgotten {
                records[key] = nil
            }
        }

        // Moved-away files can't count as registered either.
        let movedSet = Set(setAside)
        let register = plan.register.filter { !movedSet.contains($0) }
        if !register.isEmpty {
            try ExportManifest.appendRecords(
                register.map { (ExportManifest.iCloudPathPrefix + $0, [$0]) }, in: destination
            )
            for path in register {
                records[ExportManifest.iCloudPathPrefix + path] = [path]
            }
        }

        // The snapshot covers everything listed (the user's own files too, so the next quick check still sees
        // them in unchanged folders), minus what was moved away.
        var snapshot = inventory.snapshot
        for path in setAside {
            snapshot.files[path] = nil
        }
        try? ExportManifest.writeFilesSnapshot(snapshot, in: destination)

        return report(input, inventory: inventory, plan: plan, records: records,
                      setAside: setAside, register: register, started: started)
    }

    private static func report(
        _ input: Input,
        inventory: DriveInventory.Result,
        plan: Plan,
        records: [String: [String]],
        setAside: [String],
        register: [String],
        started: ContinuousClock.Instant
    ) -> DriveCheckReport {
        let counted = onDrive(records: records, source: input.source, selection: input.selection,
                              selectedCount: input.selectedCount, libraryIDs: input.libraryIDs)
        let elapsed = started.duration(to: .now)
        return DriveCheckReport(
            mode: inventory.mode,
            selectedCount: input.selectedCount,
            onDrive: counted.count,
            isApproximate: counted.isApproximate,
            toGo: max(0, input.selectedCount - counted.count),
            missingItems: plan.missing.count,
            missingFiles: plan.missing.values.flatMap { $0 }.sorted(),
            damagedFiles: Array(Set(plan.damaged.values.flatMap { $0 })).sorted(),
            setAsideFiles: setAside,
            setAsideFolder: input.setAsideFolder,
            registeredFiles: register,
            otherFiles: plan.otherFiles,
            partialFiles: inventory.partialFileCount + plan.partialItemFiles,
            partialItems: plan.partialItems,
            filesListed: inventory.files.count,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
    }
}
