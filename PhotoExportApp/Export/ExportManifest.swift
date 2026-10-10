import Foundation

/// Records which library items have been exported to a destination, so a later
/// run can skip them. Lives in a hidden `.photo-export` folder inside the
/// destination: `exported.tsv` is an append-only journal of
/// `localIdentifier<TAB>relative path…` lines, and `run-in-progress` exists
/// while a run hasn't finished cleanly.
final class ExportManifest {
    private static let folderName = ".photo-export"
    private static let journalName = "exported.tsv"
    private static let markerName = "run-in-progress"

    private let markerURL: URL
    private let journal: FileHandle
    private var exportedIDs: Set<String>

    /// Opens the manifest for a new run and marks the run as in progress.
    init(destination: URL) throws {
        let directory = destination.appending(path: Self.folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let journalURL = directory.appending(path: Self.journalName)
        let contents = Self.readJournal(at: journalURL)
        exportedIDs = contents.ids
        if !FileManager.default.fileExists(atPath: journalURL.path(percentEncoded: false)) {
            try Data().write(to: journalURL)
        }
        journal = try FileHandle(forWritingTo: journalURL)
        try journal.seekToEnd()
        if contents.endsMidLine {
            // An interrupted write left a partial line; start on a fresh one.
            try journal.write(contentsOf: Data("\n".utf8))
        }

        markerURL = directory.appending(path: Self.markerName)
        try Data().write(to: markerURL)
    }

    deinit {
        try? journal.close()
    }

    func contains(_ localIdentifier: String) -> Bool {
        exportedIDs.contains(localIdentifier)
    }

    func recordExport(of localIdentifier: String, files: [String]) throws {
        let line = ([localIdentifier] + files).joined(separator: "\t") + "\n"
        try journal.write(contentsOf: Data(line.utf8))
        exportedIDs.insert(localIdentifier)
    }

    func markRunFinished() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    // MARK: - Reading without starting a run

    static func exportedIDs(in destination: URL) -> Set<String> {
        let directory = destination.appending(path: folderName, directoryHint: .isDirectory)
        return readJournal(at: directory.appending(path: journalName)).ids
    }

    static func hasIncompleteRun(in destination: URL) -> Bool {
        let marker = destination.appending(path: folderName, directoryHint: .isDirectory).appending(path: markerName)
        return FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
    }

    private static func readJournal(at url: URL) -> (ids: Set<String>, endsMidLine: Bool) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], false) }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n")
        let endsMidLine = !text.hasSuffix("\n")
        if endsMidLine {
            lines.removeLast()
        }
        let ids = lines.compactMap { $0.split(separator: "\t", maxSplits: 1).first.map(String.init) }
        return (Set(ids), endsMidLine)
    }
}
