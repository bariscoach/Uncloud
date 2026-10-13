import Foundation

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
    /// The iCloud resume point (`ICloudResumePoint.fileName`).
    private static let resumePointName = "resume.json"
    /// Journal key prefix for iCloud items recorded by asset ID: `icloud-id:<assetID><TAB>path…`.
    static let iCloudIDPrefix = "icloud-id:"
    /// Journal key prefix for iCloud items that are only partly on the drive, such as a Live Photo whose
    /// movie failed: `icloud-partial:<assetID><TAB>path…`. They don't count as exported; their files aren't
    /// taken for untracked downloads. An `icloud-id:` record for the same asset supersedes it.
    static let iCloudPartialPrefix = "icloud-partial:"
    /// Journal key prefix for files recorded by path, without an asset ID (icloudpd runs, the drive check).
    static let iCloudPathPrefix = "icloud:"

    private let destination: URL
    private let markerURL: URL
    private let layoutURL: URL
    private let journal: FileHandle
    private let checksumJournal: FileHandle
    private var exportedIDs: Set<String>

    /// Opens the manifest for a new run and marks the run as in progress.
    init(destination: URL) throws {
        self.destination = destination
        let directory = Self.folder(in: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let journalURL = directory.appending(path: Self.journalName)
        let contents = Self.readLines(at: journalURL)
        exportedIDs = Set(contents.lines.compactMap { Self.firstField(of: $0) })
        journal = try Self.openForAppending(journalURL, endsMidLine: contents.endsMidLine)

        let checksumsURL = directory.appending(path: Self.checksumsName)
        let checksumContents = Self.readLines(at: checksumsURL)
        checksumJournal = try Self.openForAppending(checksumsURL, endsMidLine: checksumContents.endsMidLine)

        markerURL = directory.appending(path: Self.markerName)
        layoutURL = directory.appending(path: Self.layoutName)
        try Data().write(to: markerURL)
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
        exportedIDs.insert(localIdentifier)
    }

    /// Appends one `relative path<TAB>sha256` line per entry.
    func recordChecksums(_ checksums: [String: String]) throws {
        let text = checksums.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)\n" }.joined()
        guard !text.isEmpty else { return }
        try checksumJournal.write(contentsOf: Data(text.utf8))
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
    private static func requireInsideDestination(_ relativePath: String, in destination: URL) throws {
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
        let handle = try openForAppending(url, endsMidLine: readLines(at: url).endsMidLine)
        defer { try? handle.close() }
        let text = records.map { ([$0.key] + $0.paths).joined(separator: "\t") + "\n" }.joined()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func markRunFinished() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    // MARK: - Reading without starting a run

    static func exportedIDs(in destination: URL) -> Set<String> {
        let directory = destination.appending(path: folderName, directoryHint: .isDirectory)
        return readJournal(at: directory.appending(path: journalName)).ids
    }

    /// The relative paths recorded for each item, from `exported.tsv`. A later line for the same item replaces the earlier one.
    static func records(in destination: URL) -> [String: [String]] {
        let url = folder(in: destination).appending(path: journalName)
        var records: [String: [String]] = [:]
        for line in readLines(at: url).lines {
            let fields = line.split(separator: "\t").map(String.init)
            guard let id = fields.first else { continue }
            records[id] = Array(fields.dropFirst())
        }
        return records
    }

    /// The recorded SHA-256 for each relative path, from `checksums.tsv`. A later line for the same path wins.
    static func checksums(in destination: URL) -> [String: String] {
        var checksums: [String: String] = [:]
        for line in readLines(at: folder(in: destination).appending(path: checksumsName)).lines {
            let fields = line.split(separator: "\t", maxSplits: 1)
            // A line cut short by a crash has an incomplete digest; skip it so the file reads as unverifiable, not damaged.
            guard fields.count == 2, fields[1].count == 64, fields[1].allSatisfy(\.isHexDigit) else { continue }
            checksums[String(fields[0])] = String(fields[1])
        }
        return checksums
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

    /// Deletes `.photo-export/resume.json`, so the next whole-library iCloud export walks the whole library
    /// instead of continuing from its anchor. A missing point reads as "no point". Removing a file is atomic;
    /// a point that's already gone is fine.
    static func invalidateResumePoint(in destination: URL) throws {
        let url = folder(in: destination).appending(path: resumePointName)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
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

    private static func folder(in destination: URL) -> URL {
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

    private static func readJournal(at url: URL) -> (ids: Set<String>, endsMidLine: Bool) {
        let contents = readLines(at: url)
        let ids = contents.lines.compactMap { firstField(of: $0) }
        return (Set(ids), contents.endsMidLine)
    }

    /// The complete lines of a file, without a partial last line.
    private static func readLines(at url: URL) -> (lines: [Substring], endsMidLine: Bool) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], false) }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n")
        let endsMidLine = !text.hasSuffix("\n")
        if endsMidLine {
            lines.removeLast()
        }
        return (lines, endsMidLine)
    }

    private static func firstField(of line: Substring) -> String? {
        line.split(separator: "\t", maxSplits: 1).first.map(String.init)
    }

    /// Opens a file for appending, creating it if needed. A partial last line is cut off first: readers
    /// already skip it, and finishing it with a newline would make it a complete, wrong record.
    private static func openForAppending(_ url: URL, endsMidLine: Bool) throws -> FileHandle {
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
