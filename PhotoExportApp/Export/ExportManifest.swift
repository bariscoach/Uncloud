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

    private let markerURL: URL
    private let layoutURL: URL
    private let journal: FileHandle
    private let checksumJournal: FileHandle
    private var exportedIDs: Set<String>

    /// Opens the manifest for a new run and marks the run as in progress.
    init(destination: URL) throws {
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
    static func forget(_ localIdentifiers: Set<String>, in destination: URL) throws {
        guard !localIdentifiers.isEmpty else { return }
        let directory = folder(in: destination)

        let forgotten = records(in: destination).filter { localIdentifiers.contains($0.key) }
        let forgottenPaths = Set(forgotten.values.flatMap { $0 })

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

    static func hasIncompleteRun(in destination: URL) -> Bool {
        let marker = folder(in: destination).appending(path: markerName)
        return FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
    }

    static func layout(in destination: URL) -> FolderLayout? {
        let url = folder(in: destination).appending(path: layoutName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return FolderLayout(rawValue: String(decoding: data, as: UTF8.self))
    }

    private static func folder(in destination: URL) -> URL {
        destination.appending(path: folderName, directoryHint: .isDirectory)
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

    /// Replaces a file's contents through a temporary file in the same folder.
    private static func replaceFile(at url: URL, with text: String) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        try Data(text.utf8).write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
