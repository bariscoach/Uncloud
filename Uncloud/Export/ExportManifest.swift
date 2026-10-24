import Foundation
import os

/// Records which library items have been exported to a destination, so a later
/// run can skip them. Lives in a hidden `.photo-export` folder inside the
/// destination: `exported.tsv` is an append-only journal of
/// `localIdentifier<TAB>relative path…` lines, `checksums.tsv` holds
/// `relative path<TAB>sha256` lines for the exported files, `run-in-progress`
/// exists while a run hasn't finished cleanly, and `layout` holds the folder
/// layout of the most recent run.
final class ExportManifest {
    private static let folderName = ".photo-export"
    private static let journalName = "exported.tsv"
    private static let checksumsName = "checksums.tsv"
    private static let markerName = "run-in-progress"
    private static let layoutName = "layout"
    private static let filesSnapshotName = "files.tsv"
    private static let setAsideFolderName = "set-aside"
    /// Journal key prefix for iCloud items recorded by asset ID: `icloud-id:<assetID><TAB>path…`.
    static let iCloudIDPrefix = "icloud-id:"
    /// Journal key prefix for iCloud items that are only partly on the drive, such as a Live Photo whose
    /// movie failed: `icloud-partial:<assetID><TAB>path…`. They don't count as exported; their files aren't
    /// taken for untracked downloads. An `icloud-id:` record for the same asset supersedes it.
    static let iCloudPartialPrefix = "icloud-partial:"
    /// Journal key prefix for files recorded by path, without an asset ID (icloudpd runs, the drive check).
    static let iCloudPathPrefix = "icloud:"
    /// Journal key prefix for files imported from Google Takeout, keyed by the file's SHA-256: `google:<sha256>`.
    /// Takeout items have no library ID. Readers that count iCloud or Photos items must skip these records.
    static let googleKeyPrefix = "google:"

    private let destination: URL
    private let journalURL: URL
    private let checksumsURL: URL
    private let markerURL: URL
    private let layoutURL: URL
    private let journal: FileHandle
    private let checksumJournal: FileHandle
    private var exportedIDs: Set<String>

    /// Opens the manifest for a new run and marks the run as in progress. `marksRun: false` opens it without that
    /// marker, for work that isn't an export run (the Google Takeout import keeps its own journal).
    init(destination: URL, marksRun: Bool = true) throws {
        self.destination = destination
        let directory = Self.folder(in: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        journalURL = directory.appending(path: Self.journalName)
        exportedIDs = ManifestTextCache.ids(at: journalURL)
        journal = try Self.openForAppending(journalURL, endsMidLine: Self.endsMidLine(at: journalURL))

        checksumsURL = directory.appending(path: Self.checksumsName)
        checksumJournal = try Self.openForAppending(checksumsURL, endsMidLine: Self.endsMidLine(at: checksumsURL))

        markerURL = directory.appending(path: Self.markerName)
        layoutURL = directory.appending(path: Self.layoutName)
        if marksRun {
            try Data().write(to: markerURL)
        }
    }

    deinit {
        try? journal.close()
        try? checksumJournal.close()
    }

    func contains(_ localIdentifier: String) -> Bool {
        exportedIDs.contains(localIdentifier)
    }

    func recordExport(of localIdentifier: String, files: [String]) throws {
        let line = ([localIdentifier] + files).joined(separator: "\t") + "\n"
        try journal.write(contentsOf: Data(line.utf8))
        ManifestTextCache.invalidate(journalURL)
        exportedIDs.insert(localIdentifier)
    }

    /// Appends one `relative path<TAB>sha256` line per entry.
    func recordChecksums(_ checksums: [String: String]) throws {
        let text = checksums.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)\n" }.joined()
        guard !text.isEmpty else { return }
        try checksumJournal.write(contentsOf: Data(text.utf8))
        ManifestTextCache.invalidate(checksumsURL)
    }

    func recordLayout(_ layout: FolderLayout) throws {
        try Data(layout.rawValue.utf8).write(to: layoutURL, options: .atomic)
    }

    /// Records an iCloud item by its asset ID, with the relative paths of its files:
    /// `icloud-id:<assetID><TAB>path<TAB>path…`. A later record for the same ID replaces the earlier one.
    /// Older app versions read the line as an opaque ID, so they keep working. Nothing is written for an empty `paths`.
    func recordICloudItem(id: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let fields = [id] + paths
        guard fields.allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }), !id.isEmpty else {
            throw ManifestError.unrecordableField
        }
        let line = Self.iCloudIDPrefix + fields.joined(separator: "\t") + "\n"
        try journal.write(contentsOf: Data(line.utf8))
        ManifestTextCache.invalidate(journalURL)
        exportedIDs.insert(Self.iCloudIDPrefix + id)
    }

    /// Records the files an iCloud item left on the drive when it failed partway, such as a Live Photo whose
    /// movie couldn't be downloaded: `icloud-partial:<assetID><TAB>path…`. Nothing is written for an empty `paths`.
    func recordPartialICloudItem(id: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let fields = [id] + paths
        guard fields.allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }), !id.isEmpty else {
            throw ManifestError.unrecordableField
        }
        let line = Self.iCloudPartialPrefix + fields.joined(separator: "\t") + "\n"
        try journal.write(contentsOf: Data(line.utf8))
        ManifestTextCache.invalidate(journalURL)
    }

    /// Writes the files.tsv snapshot. The file is replaced as a whole, so a crash leaves the old snapshot or the new one.
    func writeFilesSnapshot(_ snapshot: FilesSnapshot) throws {
        try Self.writeFilesSnapshot(snapshot, in: destination)
    }

    /// `writeFilesSnapshot(_:)` without opening a run, for the drive check.
    static func writeFilesSnapshot(_ snapshot: FilesSnapshot, in destination: URL) throws {
        let directory = folder(in: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(snapshot.tsv.utf8).write(to: directory.appending(path: filesSnapshotName), options: .atomic)
    }

    /// Moves files into `.photo-export/set-aside/<session>/<relative path>` instead of deleting them. Used for
    /// damaged or truncated files that are about to be downloaded again. Never overwrites: a name already taken
    /// gets a number, like `IMG_0001 (1).HEIC`. Paths that don't exist are skipped.
    /// Returns the new location of each file that was moved, keyed by its original relative path.
    @discardableResult
    func setAside(paths: [String], session: String) throws -> [String: URL] {
        try Self.setAside(paths: paths, session: session, in: destination)
    }

    /// `setAside(paths:session:)` without opening a run, for the drive check.
    @discardableResult
    static func setAside(paths: [String], session: String, in destination: URL) throws -> [String: URL] {
        guard isSafeComponent(session) else { throw ManifestError.unsafePath(session) }
        // Check every path before moving any, so a refused call changes nothing.
        if let unsafe = paths.first(where: { !isSafeRelativePath($0) }) {
            throw ManifestError.unsafePath(unsafe)
        }
        // The path text is safe; the folders on it must be real folders inside the destination too. A symbolic
        // link anywhere on the way (a folder or the file itself) could make the move reach outside it.
        try requireInsideDestination(".photo-export/\(setAsideFolderName)/\(session)", in: destination)
        for path in paths {
            try requireInsideDestination(path, in: destination)
        }
        let sessionFolder = folder(in: destination)
            .appending(path: setAsideFolderName, directoryHint: .isDirectory)
            .appending(path: session, directoryHint: .isDirectory)
        var moved: [String: URL] = [:]
        for path in paths {
            // Checked again right before the move, in case a folder was swapped for a link meanwhile, and the
            // place it goes to as well.
            try requireInsideDestination(path, in: destination)
            try requireInsideDestination(".photo-export/\(setAsideFolderName)/\(session)/\(path)", in: destination)
            let source = destination.appending(path: path)
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { continue }

            let target = uniqueURL(for: sessionFolder.appending(path: path))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
            moved[path] = target
        }
        return moved
    }

    /// Throws `unsafePath` unless every existing component of `relativePath` under `destination` is a plain file or
    /// folder (not a symbolic link), and the resolved location stays inside the resolved destination.
    static func requireInsideDestination(_ relativePath: String, in destination: URL) throws {
        let fileManager = FileManager.default
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        var current = destination.standardizedFileURL
        for component in relativePath.split(separator: "/") {
            current = current.appending(path: String(component))
            let path = current.path(percentEncoded: false)
            // lstat: attributesOfItem doesn't follow a final symbolic link.
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { break }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ManifestError.unsafePath(relativePath)
            }
        }
        // Where the deepest existing folder on the path really is: inside the destination, wherever that is
        // (the destination itself may be reached through a link, such as /Volumes or /var).
        var existing = destination.appending(path: relativePath).deletingLastPathComponent().standardizedFileURL
        while !fileManager.fileExists(atPath: existing.path(percentEncoded: false)), existing.pathComponents.count > 1 {
            existing = existing.deletingLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        guard resolved == rootPath || resolved.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw ManifestError.unsafePath(relativePath)
        }
    }

    /// Appends records (`key<TAB>path…`) to `exported.tsv` without opening a run, for the drive check.
    /// A cut-off last line is removed first, as when a run opens the journal. Don't call while an export runs.
    static func appendRecords(_ records: [(key: String, paths: [String])], in destination: URL) throws {
        guard !records.isEmpty else { return }
        let fields = records.flatMap { [$0.key] + $0.paths }
        guard fields.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw ManifestError.unrecordableField
        }
        let directory = folder(in: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: journalName)
        let handle = try openForAppending(url, endsMidLine: endsMidLine(at: url))
        defer { try? handle.close() }
        let text = records.map { ([$0.key] + $0.paths).joined(separator: "\t") + "\n" }.joined()
        try handle.write(contentsOf: Data(text.utf8))
        ManifestTextCache.invalidate(url)
    }

    func markRunFinished() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    // MARK: - Reading without starting a run

    static func exportedIDs(in destination: URL) -> Set<String> {
        ManifestTextCache.ids(at: folder(in: destination).appending(path: journalName))
    }

    /// The relative paths recorded for each item, from `exported.tsv`. A later line for the same item replaces the earlier one.
    static func records(in destination: URL) -> [String: [String]] {
        ManifestTextCache.records(at: folder(in: destination).appending(path: journalName))
    }

    /// The last `limit` records of `exported.tsv`, oldest first: each item's ID and relative paths. The journal is
    /// append-only, so these are the most recent exports.
    static func recentRecords(in destination: URL, limit: Int) -> [(id: String, paths: [String])] {
        let url = folder(in: destination).appending(path: journalName)
        return readLines(at: url).lines.suffix(limit).compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            guard let id = fields.first else { return nil }
            return (id, Array(fields.dropFirst()))
        }
    }

    /// The line each record's first export is on in `exported.tsv`, so records can be ordered by when they were first exported.
    static func firstRecordPositions(in destination: URL) -> [String: Int] {
        var positions: [String: Int] = [:]
        for (index, line) in readLines(at: folder(in: destination).appending(path: journalName)).lines.enumerated() {
            if let id = firstField(of: line), positions[id] == nil {
                positions[id] = index
            }
        }
        return positions
    }

    /// The recorded SHA-256 for each relative path, from `checksums.tsv`. A later line for the same path wins.
    /// A line cut short by a crash has an incomplete digest; it is skipped so the file reads as unverifiable, not damaged.
    static func checksums(in destination: URL) -> [String: String] {
        ManifestTextCache.checksums(at: folder(in: destination).appending(path: checksumsName))
    }

    /// Removes items from `exported.tsv` and their paths from `checksums.tsv`, so the next run exports them again.
    /// Files already on disk are left alone. Don't call while an export is running.
    ///
    /// Forgetting any iCloud record (`icloud-id:` or `icloud:`) invalidates the resume point first: the point
    /// promises that every item above its anchor is on the drive, which is no longer true, so the next export
    /// walks the whole library and fetches the forgotten items again.
    static func forget(_ localIdentifiers: Set<String>, in destination: URL) throws {
        guard !localIdentifiers.isEmpty else { return }
        let directory = folder(in: destination)

        let forgotten = records(in: destination).filter { localIdentifiers.contains($0.key) }
        let forgottenPaths = Set(forgotten.values.flatMap { $0 })
        if forgotten.keys.contains(where: { $0.hasPrefix(iCloudIDPrefix) || $0.hasPrefix(iCloudPathPrefix) }) {
            try invalidateResumePoint(in: destination)
        }

        let journalURL = directory.appending(path: journalName)
        let keptJournal = readLines(at: journalURL).lines.filter { line in
            guard let id = firstField(of: line) else { return false }
            return !localIdentifiers.contains(id)
        }
        try replaceFile(at: journalURL, with: keptJournal.map { $0 + "\n" }.joined())

        let checksumsURL = directory.appending(path: checksumsName)
        if FileManager.default.fileExists(atPath: checksumsURL.path(percentEncoded: false)) {
            let keptChecksums = readLines(at: checksumsURL).lines.filter { line in
                guard let path = firstField(of: line) else { return false }
                return !forgottenPaths.contains(path)
            }
            try replaceFile(at: checksumsURL, with: keptChecksums.map { $0 + "\n" }.joined())
        }
    }

    /// Deletes every resume point in `.photo-export` (one per layout, and the legacy `resume.json`), so the next
    /// whole-library iCloud export walks the whole library instead of continuing from its anchor. Forgotten items
    /// are gone from every layout's point, so all of them go. A missing point reads as "no point"; removing a file
    /// is atomic, and a point that's already gone is fine.
    static func invalidateResumePoint(in destination: URL) throws {
        let directory = folder(in: destination)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where ICloudResumePoint.isResumeFileName(name) {
            do {
                try FileManager.default.removeItem(at: directory.appending(path: name))
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                continue
            }
        }
    }

    static func hasIncompleteRun(in destination: URL) -> Bool {
        let marker = folder(in: destination).appending(path: markerName)
        return FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
    }

    static func layout(in destination: URL) -> FolderLayout? {
        let url = folder(in: destination).appending(path: layoutName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return FolderLayout(rawValue: String(decoding: data, as: UTF8.self))
    }

    /// The last files.tsv snapshot, or nil when the drive has none yet (older app versions never wrote one).
    static func filesSnapshot(in destination: URL) -> FilesSnapshot? {
        let url = folder(in: destination).appending(path: filesSnapshotName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return FilesSnapshot(tsv: String(decoding: data, as: UTF8.self))
    }

    /// The iCloud items recorded by asset ID (`icloud-id:` records): asset ID to relative paths.
    /// Legacy `icloud:<path>` records are not included; they have no asset ID.
    static func iCloudItems(in destination: URL) -> [String: [String]] {
        var items: [String: [String]] = [:]
        for (key, paths) in records(in: destination) where key.hasPrefix(iCloudIDPrefix) {
            items[String(key.dropFirst(iCloudIDPrefix.count))] = paths
        }
        return items
    }

    /// Rewrites the manifest's paths after a reorganize (R17b). `map` is `old relative path → new relative path`, or
    /// the inverse for an undo. Each file is replaced atomically and its cache is dropped. A file that doesn't change
    /// is not written:
    /// 1. `exported.tsv`: every path field (not the key) found in `map`, on every line. Keys and line order stay the
    ///    same, so `firstRecordPositions` doesn't change. A partial last line stays as it was.
    /// 2. `checksums.tsv`: the path in the first field.
    /// 3. `files.tsv`: the path of each `file` line. Every `dir` line is dropped; the next drive check rescans folders.
    /// 4. The resume point: the other of flat and month's point becomes `layout`'s point (`resume-<layout>.json`). Ranks don't depend on
    ///    paths, so the point stays valid.
    /// 5. `layout`: written as `layout`.
    /// It is idempotent. Map keys have no `/` and map values always do, so a second call finds no path to change.
    static func relocate(_ map: [String: String], in destination: URL, layout: FolderLayout) throws {
        let directory = folder(in: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try rewriteIfChanged(directory.appending(path: journalName)) { data in
            mapLines(data) { line in
                mapFields(line, from: 1, map)
            }
        }
        try rewriteIfChanged(directory.appending(path: checksumsName)) { data in
            mapLines(data) { line in
                mapFields(line, from: 0, map, first: true)
            }
        }
        try rewriteIfChanged(directory.appending(path: filesSnapshotName)) { data in
            mapLines(data) { line -> Data? in
                let text = String(decoding: line, as: UTF8.self)
                if text.hasPrefix("dir\t") { return nil }
                guard text.hasPrefix("file\t") else { return line }
                return mapFields(line, from: 1, map, only: 1)
            }
        }

        // The point moves with the files: the other of flat and month becomes this layout's point.
        let other: FolderLayout? = layout == .flat ? .month : (layout == .month ? .flat : nil)
        if let other, var point = ICloudResumePoint.load(in: destination, layout: other), point.layout == other.rawValue {
            point.layout = layout.rawValue
            try point.save(in: destination)
            ICloudResumePoint.remove(in: destination, layout: other)
        }
        try Data(layout.rawValue.utf8).write(to: directory.appending(path: layoutName), options: .atomic)
    }

    /// Replaces the file's contents with `transform(contents)` when that differs from the current contents.
    private static func rewriteIfChanged(_ url: URL, _ transform: (Data) -> Data) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        let updated = transform(data)
        guard updated != data else { return }
        try replaceFile(at: url, with: String(decoding: updated, as: UTF8.self))
    }

    /// Applies `transform` to every LF-terminated line; a `nil` drops the line. A last line with no LF is partial and
    /// is kept as it was. Works on bytes, so a CR before an LF is just a byte.
    private static func mapLines(_ data: Data, _ transform: (Data) -> Data?) -> Data {
        var output = Data()
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: ManifestLines.lf) {
            if let line = transform(data[start ..< newline]) {
                output += line
                output.append(ManifestLines.lf)
            }
            start = newline + 1
        }
        output += data[start...]
        return output
    }

    /// The tab-separated fields of `line` from index `from` on, with each one that `map` knows replaced. With
    /// `first`, only field 0 is considered (the `from` value is ignored). With `only`, only that field index is.
    private static func mapFields(_ line: Data, from: Int, _ map: [String: String], first: Bool = false, only: Int? = nil) -> Data {
        var fields = String(decoding: line, as: UTF8.self).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        var changed = false
        for index in fields.indices where (first ? index == 0 : index >= from) && (only == nil || index == only) {
            if let replacement = map[fields[index]] {
                fields[index] = replacement
                changed = true
            }
        }
        return changed ? Data(fields.joined(separator: "\t").utf8) : line
    }

    /// The hidden `.photo-export` folder inside a destination, where the manifest files live.
    static func folder(in destination: URL) -> URL {
        destination.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// A relative path made of plain components: no leading slash, no `.`/`..`/empty parts, no control characters.
    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { isSafeComponent(String($0)) }
            && path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// `path` if nothing is there yet, otherwise `name (1).ext`, `name (2).ext`, and so on.
    private static func uniqueURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            let candidate = directory.appending(path: name)
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            number += 1
        }
    }

    /// The complete lines of a file, without a partial last line.
    private static func readLines(at url: URL) -> (lines: [String], endsMidLine: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([], false) }
        return ManifestLines.lines(in: data)
    }

    /// Whether a file ends in the middle of a line, read from its last two bytes only.
    static func endsMidLine(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        let from = size > 2 ? size - 2 : 0
        guard (try? handle.seek(toOffset: from)) != nil, let tail = try? handle.read(upToCount: Int(size - from)) else {
            return false
        }
        return ManifestLines.endsMidLine(lastBytes: tail)
    }

    private static func firstField(of line: String) -> String? {
        line.split(separator: "\t", maxSplits: 1).first.map(String.init)
    }

    /// Opens a file for appending, creating it if needed. A partial last line is cut off first: readers
    /// already skip it, and finishing it with a newline would make it a complete, wrong record.
    static func openForAppending(_ url: URL, endsMidLine: Bool) throws -> FileHandle {
        ManifestTextCache.invalidate(url)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        if endsMidLine {
            let contents = try Data(contentsOf: url)
            let keep = contents.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
            try handle.truncate(atOffset: UInt64(keep))
        }
        try handle.seekToEnd()
        return handle
    }

    /// Replaces a file's contents through a temporary file in the same folder. The temporary file is forced to
    /// the disk before the rename, and the folder after it, so a crash or an unplugged drive leaves the old
    /// contents or the new ones, never an empty or partial file.
    private static func replaceFile(at url: URL, with text: String) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).tmp")
        try Data(text.utf8).write(to: temporary)
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        ManifestTextCache.invalidate(url)
        // The rename itself, best effort: not every file system supports syncing a folder.
        let descriptor = open(directory.path(percentEncoded: false), O_RDONLY)
        if descriptor >= 0 {
            _ = fsync(descriptor)
            close(descriptor)
        }
    }
}

/// What the manifest refuses to write or move.
enum ManifestError: Error, Equatable {
    /// An ID or path would break the tab-separated lines (a tab or line break, or an empty ID).
    case unrecordableField
    /// A path or session name that could point outside the destination or its `.photo-export` folder.
    case unsafePath(String)
}

/// The `files.tsv` snapshot: what the last drive check saw, kept so the next quick check can tell which
/// folders changed. Stored as lines, in sorted order:
/// - `file<TAB>relative path<TAB>size<TAB>modification time`
/// - `dir<TAB>relative folder<TAB>modification time` (the destination root is the empty string)
/// Times are seconds since 1970. Lines that don't parse are skipped.
struct FilesSnapshot: Equatable, Sendable {
    struct FileEntry: Equatable, Sendable {
        var size: Int64
        var modified: Double
    }

    /// Relative path to its size and modification time.
    var files: [String: FileEntry]
    /// Relative folder to its modification time.
    var directories: [String: Double]

    init(files: [String: FileEntry] = [:], directories: [String: Double] = [:]) {
        self.files = files
        self.directories = directories
    }

    init(tsv: String) {
        var snapshot = FilesSnapshot()
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch fields.first {
            case "file" where fields.count == 4:
                if let size = Int64(fields[2]), let modified = Double(fields[3]) {
                    snapshot.files[String(fields[1])] = FileEntry(size: size, modified: modified)
                }
            case "dir" where fields.count == 3:
                if let modified = Double(fields[2]) {
                    snapshot.directories[String(fields[1])] = modified
                }
            default:
                continue
            }
        }
        self = snapshot
    }

    var tsv: String {
        var lines: [String] = []
        lines.reserveCapacity(files.count + directories.count)
        for (path, entry) in files {
            lines.append("file\t\(path)\t\(entry.size)\t\(entry.modified)")
        }
        for (folder, modified) in directories {
            lines.append("dir\t\(folder)\t\(modified)")
        }
        return lines.sorted().map { $0 + "\n" }.joined()
    }
}

/// Byte-level readers for the manifest's tab-separated text. They keep the semantics of the `String.split` parsing
/// they replaced, which the tests check against a copy of that parser:
/// - an LF ends a line, unless a CR comes right before it (Swift reads CR LF as one character, so splitting on LF
///   never broke there);
/// - empty lines are dropped, and so are empty fields;
/// - a last line with no LF is partial and is skipped;
/// - `checksums` and `exportedIDs` split at the first tab only, skipping leading tabs as `split(maxSplits: 1)` does.
enum ManifestLines {
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let tab: UInt8 = 0x09

    /// Calls `body` with the byte range of each complete, non-empty line. Returns whether the data ends mid-line.
    /// The first `byte` in `bytes[from..<to]`, or `to` when there is none. `memchr` does the scan, so the search
    /// costs the same in an unoptimized build as in a release one.
    static func find(_ byte: UInt8, in bytes: UnsafeRawBufferPointer, from: Int, to: Int) -> Int {
        guard from < to, let base = bytes.baseAddress else { return to }
        guard let found = memchr(base + from, Int32(byte), to - from) else { return to }
        return base.distance(to: UnsafeRawPointer(found))
    }

    /// Calls `body` with the byte range of each complete, non-empty line. Returns whether the data ends mid-line.
    static func forEachLine(in bytes: UnsafeRawBufferPointer, _ body: (Range<Int>) -> Void) -> Bool {
        let count = bytes.count
        var start = 0
        var search = 0
        while search < count {
            let index = find(lf, in: bytes, from: search, to: count)
            guard index < count else { break }
            search = index + 1
            // CR LF is one character to Swift, so the line doesn't end at this LF.
            if index > 0 && bytes[index - 1] == cr { continue }
            if index > start { body(start..<index) }
            start = index + 1
        }
        return start < count
    }

    /// Calls `body` with each non-empty tab-separated field of a line.
    static func forEachField(in bytes: UnsafeRawBufferPointer, _ line: Range<Int>, _ body: (Range<Int>) -> Void) {
        var index = line.lowerBound
        while index < line.upperBound {
            if bytes[index] == tab {
                index += 1
                continue
            }
            let end = find(tab, in: bytes, from: index, to: line.upperBound)
            body(index..<end)
            index = end
        }
    }

    /// The key and the rest of a line, as `split(separator: "\t", maxSplits: 1)` gives them with empty pieces dropped:
    /// the key is the first non-empty piece, and `rest` is everything after the next tab (tabs and all), or nil.
    static func keyAndRest(in bytes: UnsafeRawBufferPointer, _ line: Range<Int>) -> (key: Range<Int>, rest: Range<Int>?)? {
        var index = line.lowerBound
        while index < line.upperBound && bytes[index] == tab { index += 1 }
        guard index < line.upperBound else { return nil }
        let end = find(tab, in: bytes, from: index, to: line.upperBound)
        guard end + 1 < line.upperBound else { return (index..<end, nil) }
        return (index..<end, (end + 1)..<line.upperBound)
    }

    static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// Whether data ends mid-line, given its last one or two bytes.
    static func endsMidLine(lastBytes tail: Data) -> Bool {
        guard tail.last == lf else { return !tail.isEmpty }
        return tail.count == 2 && tail.first == cr
    }

    /// The complete lines of `data`, as text. Same result as splitting the whole text, but decodes one line at a time.
    static func lines(in data: Data) -> (lines: [String], endsMidLine: Bool) {
        data.withUnsafeBytes { raw in
            var lines: [String] = []
            let endsMidLine = forEachLine(in: raw) { lines.append(String(decoding: raw[$0], as: UTF8.self)) }
            return (lines, endsMidLine)
        }
    }

    /// `exported.tsv` as the relative paths of each item. A later line for an item replaces the earlier one.
    static func parseRecords(_ data: Data) -> [String: [String]] {
        data.withUnsafeBytes { raw in
            var records: [String: [String]] = [:]
            _ = forEachLine(in: raw) { line in
                var fields: [String] = []
                forEachField(in: raw, line) { fields.append(String(decoding: raw[$0], as: UTF8.self)) }
                guard let id = fields.first else { return }
                records[id] = Array(fields.dropFirst())
            }
            return records
        }
    }

    /// `exported.tsv` as the set of its item keys (the first field of each line).
    static func parseIDs(_ data: Data) -> Set<String> {
        data.withUnsafeBytes { raw in
            var ids: Set<String> = []
            _ = forEachLine(in: raw) { line in
                guard let parts = keyAndRest(in: raw, line) else { return }
                ids.insert(String(decoding: raw[parts.key], as: UTF8.self))
            }
            return ids
        }
    }

    /// `checksums.tsv` as relative path to digest. A later line for a path wins; lines without a 64-character hex
    /// digest are skipped.
    static func parseChecksums(_ data: Data) -> [String: String] {
        data.withUnsafeBytes { raw in
            var checksums: [String: String] = [:]
            _ = forEachLine(in: raw) { line in
                guard let parts = keyAndRest(in: raw, line), let rest = parts.rest else { return }
                // Fast path: 64 ASCII hex bytes are a 64-character digit. Anything else takes the exact check the
                // String-based parser used (Character.isHexDigit also accepts fullwidth digits, for one).
                let isPlainDigest = rest.count == 64 && raw[rest].allSatisfy(isASCIIHexDigit)
                let digest = String(decoding: raw[rest], as: UTF8.self)
                guard isPlainDigest || (digest.count == 64 && digest.allSatisfy(\.isHexDigit)) else { return }
                checksums[String(decoding: raw[parts.key], as: UTF8.self)] = digest
            }
            return checksums
        }
    }
}

/// Parsed copies of the manifest's text files, kept while the file is unchanged. An entry is reused only while the
/// file's device, inode, size and modification time (to the nanosecond) match the ones it was read with, so a change
/// by another process, a replacement by a new file, or a drive swap is picked up. `ExportManifest` also drops the
/// entry after each of its own writes. Internal rather than private so the tests can check that the cache is used.
enum ManifestTextCache {
    struct Stamp: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private struct Entry<Value: Sendable>: Sendable {
        let stamp: Stamp
        let value: Value
    }

    private struct State: Sendable {
        var ids: [String: Entry<Set<String>>] = [:]
        var records: [String: Entry<[String: [String]]>] = [:]
        var checksums: [String: Entry<[String: String]>] = [:]
        /// Parses per file path, so a test can count its own file's parses without interference from other tests.
        var parses: [String: Int] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func ids(at url: URL) -> Set<String> {
        let path = key(for: url)
        guard let stamp = Stamp(path: path) else {
            invalidate(url)
            return []
        }
        if let hit = state.withLock({ $0.ids[path] }), hit.stamp == stamp {
            return hit.value
        }
        let value = ManifestLines.parseIDs(contents(of: url))
        state.withLock {
            $0.ids[path] = Entry(stamp: stamp, value: value)
            $0.parses[path, default: 0] += 1
        }
        return value
    }

    static func records(at url: URL) -> [String: [String]] {
        let path = key(for: url)
        guard let stamp = Stamp(path: path) else {
            invalidate(url)
            return [:]
        }
        if let hit = state.withLock({ $0.records[path] }), hit.stamp == stamp {
            return hit.value
        }
        let value = ManifestLines.parseRecords(contents(of: url))
        state.withLock {
            $0.records[path] = Entry(stamp: stamp, value: value)
            $0.parses[path, default: 0] += 1
        }
        return value
    }

    static func checksums(at url: URL) -> [String: String] {
        let path = key(for: url)
        guard let stamp = Stamp(path: path) else {
            invalidate(url)
            return [:]
        }
        if let hit = state.withLock({ $0.checksums[path] }), hit.stamp == stamp {
            return hit.value
        }
        let value = ManifestLines.parseChecksums(contents(of: url))
        state.withLock {
            $0.checksums[path] = Entry(stamp: stamp, value: value)
            $0.parses[path, default: 0] += 1
        }
        return value
    }

    /// How many times the file at `url` has been parsed (not served from the cache).
    static func parseCount(at url: URL) -> Int {
        state.withLock { $0.parses[key(for: url)] ?? 0 }
    }

    /// Drops every cached value for the file at `url`.
    static func invalidate(_ url: URL) {
        let path = key(for: url)
        state.withLock {
            $0.ids[path] = nil
            $0.records[path] = nil
            $0.checksums[path] = nil
        }
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    /// The file's bytes, read after its stamp was taken (see the callers). An unreadable file counts as empty.
    private static func contents(of url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }
}
