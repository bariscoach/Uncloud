import Foundation

/// The Google Takeout import's own journal, `.photo-export/google-imported.tsv`: one `sourceKey<TAB>sha256` line for
/// each Takeout file that is done (imported, or skipped as already in the backup). A resumed import skips those
/// without reading them again. Append-only; a cut-off last line is ignored and cut off before the next append,
/// as `ExportManifest`'s journals do.
final class TakeoutImportJournal {
    static let fileName = "google-imported.tsv"

    private var imported: [String: String]
    private let handle: FileHandle

    static func url(in destination: URL) -> URL {
        ExportManifest.folder(in: destination).appending(path: fileName)
    }

    init(destination: URL) throws {
        let url = Self.url(in: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        imported = Self.parse(in: destination)
        handle = try ExportManifest.openForAppending(url, endsMidLine: ExportManifest.endsMidLine(at: url))
    }

    deinit {
        try? handle.close()
    }

    /// Whether the file with this source key is done.
    func contains(_ sourceKey: String) -> Bool {
        imported[sourceKey] != nil
    }

    /// The number of done files.
    var count: Int {
        imported.count
    }

    /// Appends the line. Call it after the file's records are in the manifest, so a crash in between only means the
    /// file is found again and recognized by its checksum.
    func record(sourceKey: String, sha256: String) throws {
        guard !sourceKey.isEmpty, !sha256.isEmpty,
              (sourceKey + sha256).rangeOfCharacter(from: .controlCharacters) == nil,
              !sourceKey.contains("\t") else {
            throw ManifestError.unrecordableField
        }
        try handle.write(contentsOf: Data("\(sourceKey)\t\(sha256)\n".utf8))
        imported[sourceKey] = sha256
    }

    /// The done files of a destination, from the journal's complete lines. A later line for a key wins.
    static func parse(in destination: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url(in: destination)) else { return [:] }
        var imported: [String: String] = [:]
        for line in ManifestLines.lines(in: data).lines {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            imported[String(fields[0])] = String(fields[1])
        }
        return imported
    }
}
