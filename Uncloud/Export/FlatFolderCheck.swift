import Foundation

/// Counts the entries in a flat export folder that no manifest record names: the "other files" figure.
enum FlatFolderCheck {
    /// The number of visible entries in `url` that aren't any record's path. Hidden names (starting with ".") don't count,
    /// and folders and symbolic links do. Nil when the folder can't be listed.
    ///
    /// One bulk listing replaces `contentsOfDirectory(atPath:)`, which on exFAT looks up each name in turn.
    static func unrecordedEntryCount(in url: URL, records: [String: [String]]) -> Int? {
        guard let entries = try? BulkDirectoryLister.list(url) else { return nil }
        let recorded = Set(records.values.flatMap { $0 })
        return entries.count { !$0.name.hasPrefix(".") && !recorded.contains($0.name) }
    }
}
