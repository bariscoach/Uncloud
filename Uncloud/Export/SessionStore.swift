import Foundation

/// Reads and writes export session files in `DEST/.photo-export/sessions/`.
///
/// Each file is `<UTC start, hyphens for colons>-<first 6 hex of id>.json`, so names sort in time order
/// and work on exFAT, FAT32 and network drives. A file is written through a dot-prefixed temporary file,
/// flushed to disk, and then moved over the old one, so a crash leaves either the old or the new version.
/// Dot-files and files that don't decode are skipped by every reader.
struct SessionStore: Sendable {
    let directory: URL

    init(destination: URL) {
        directory = destination
            .appending(path: ".photo-export", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// Every readable session, oldest first (the file name order). Undecodable files are left out.
    func list() -> [ExportSession] {
        entries().map(\.session)
    }

    /// The newest readable session file, for revealing the folder in Finder. Nil when there is none.
    func newestFileURL() -> URL? {
        entries().last?.url
    }

    /// Saves `session`, replacing its file if it has one. A new session whose name is already taken by
    /// another session gets a numeric suffix.
    func write(_ session: ExportSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: session)
        let temporary = directory.appending(path: "." + url.lastPathComponent + ".tmp")

        try Self.encoder().encode(session).write(to: temporary)
        try Self.flush(temporary)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Ends each session left `.running` by an earlier launch that stopped without finishing, as `.interrupted`.
    /// A session whose heartbeat is newer than `threshold` is left alone: another Mac may be writing it, or
    /// this launch just stopped. Returns how many sessions were changed.
    @discardableResult
    func markInterrupted(
        currentLaunch: UUID,
        olderThan threshold: TimeInterval = 120,
        now: Date = Date()
    ) throws -> Int {
        var changed = 0
        for session in list() where !session.isReadOnly
            && session.result.status == .running
            && session.launchID != currentLaunch
            && now.timeIntervalSince(session.updatedAt) > threshold {
            var stopped = session
            stopped.result = ExportSession.Result(
                status: .interrupted,
                reason: "Uncloud quit or the Mac restarted while exporting"
            )
            stopped.endedAt = session.updatedAt
            try write(stopped)
            changed += 1
        }
        return changed
    }

    /// Deletes whole chains, oldest first, until the folder holds at most `maxFiles` files and `maxBytes` bytes.
    /// The newest chain is never deleted, and neither is a chain with a running attempt. Files that don't
    /// decode are counted toward the limits but not deleted. Returns how many files were removed.
    @discardableResult
    func prune(maxFiles: Int, maxBytes: Int) throws -> Int {
        let files = allFiles()
        var fileCount = files.count
        var byteCount = files.reduce(0) { $0 + $1.bytes }

        var chains: [UUID: [(url: URL, bytes: Int, startedAt: Date, running: Bool)]] = [:]
        for entry in entries() {
            chains[entry.session.chainID, default: []].append(
                (entry.url, entry.bytes, entry.session.startedAt, entry.session.result.status == .running)
            )
        }
        // Newest first, so index 0 is the chain that is always kept.
        let ordered = chains.values.sorted { lhs, rhs in
            (lhs.map(\.startedAt).max() ?? .distantPast) > (rhs.map(\.startedAt).max() ?? .distantPast)
        }

        var removed = 0
        for chain in ordered.dropFirst().reversed() where fileCount > maxFiles || byteCount > maxBytes {
            guard !chain.contains(where: \.running) else { continue }
            for file in chain {
                try FileManager.default.removeItem(at: file.url)
                fileCount -= 1
                byteCount -= file.bytes
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Files

    /// The UTC start time with hyphens instead of colons, then the first 6 hex digits of the id, so two
    /// sessions starting in the same second can't collide. Without the `.json`.
    static func baseName(for session: ExportSession) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: session.startedAt).replacingOccurrences(of: ":", with: "-")
        return stamp + "-" + session.id.uuidString.prefix(6).lowercased()
    }

    /// The session's own file if it exists, else the first free name for it.
    private func fileURL(for session: ExportSession) -> URL {
        let base = Self.baseName(for: session)
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let url = directory.appending(path: name + ".json")
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
            if Self.read(at: url)?.id == session.id {
                return url
            }
            suffix += 1
        }
    }

    private struct Entry {
        var url: URL
        var bytes: Int
        var session: ExportSession
    }

    /// Every readable session file with its size, oldest first.
    private func entries() -> [Entry] {
        allFiles()
            .filter { $0.url.pathExtension == "json" }
            .compactMap { file in
                Self.read(at: file.url).map { Entry(url: file.url, bytes: file.bytes, session: $0) }
            }
            // The folder listing order isn't defined, and pruning depends on this being oldest first.
            .sorted { lhs, rhs in
                if lhs.session.startedAt != rhs.session.startedAt {
                    return lhs.session.startedAt < rhs.session.startedAt
                }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
    }

    /// Every visible file in the folder, including ones that don't decode.
    private func allFiles() -> [(url: URL, bytes: Int)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                return nil
            }
            return (url, values.fileSize ?? 0)
        }
    }

    private static func read(at url: URL) -> ExportSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(ExportSession.self, from: data)
    }

    /// Dates are ISO 8601 with milliseconds, so attempts that start within the same second still sort in order.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter(fractionalSeconds: true).string(from: date))
        }
        return encoder
    }

    /// Reads dates with or without fractional seconds (files from earlier builds have none).
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = dateFormatter(fractionalSeconds: true).date(from: text)
                ?? dateFormatter(fractionalSeconds: false).date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    private static func dateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    /// Forces the file's contents to the disk, so the rename that follows doesn't outrun the data.
    private static func flush(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
