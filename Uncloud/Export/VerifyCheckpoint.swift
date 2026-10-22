import CryptoKit
import Foundation

/// Where a full Verify pass stopped, so the next pass can continue instead of starting over. The checkpoint sits in
/// Application Support, not on the drive, because verifying doesn't write to the drive.
///
/// It is valid only while the journal (`exported.tsv`) still begins with the bytes it had when the checkpoint was
/// saved. The journal is append-only, so items appended since then come later in the pass. A forget, relocation or
/// Reorganize rewrites it, and then the pass starts over.
struct VerifyCheckpoint: Codable, Equatable, Sendable {
    /// The format version. Other values are ignored.
    static let schemaVersion = 1
    /// The journal's first 64 KB (or all of it, if shorter) is hashed into `journalHead`.
    static let headLength: Int64 = 64 * 1024

    var schema = VerifyCheckpoint.schemaVersion
    var startedAt: Date
    /// The journal's size when the checkpoint was saved.
    var journalBytes: Int64
    /// SHA-256 (lowercase hex) of the journal's first `min(64 KB, journalBytes)` bytes.
    var journalHead: String
    /// Index in the pass order of the first item not yet finished. Items before it are done.
    var nextItemIndex: Int
    var checkedFileCount: Int
    var verifiedCount: Int
    var damagedItemIDs: [String]
    var unverifiableItemIDs: [String]
    var missingFiles: [String]
    var damagedFiles: [String]
    var updatedAt: Date
}

/// The file a checkpoint is kept in, and when it is written.
struct VerifyCheckpointStore: Sendable {
    /// Saved after this many files have been checked since the last save, or after `saveEverySeconds`, whichever is first.
    static let defaultSaveEveryFiles = 1_000
    static let defaultSaveEverySeconds: TimeInterval = 60

    let url: URL
    let saveEveryFiles: Int
    let saveEverySeconds: TimeInterval
    let now: @Sendable () -> Date

    init(
        url: URL,
        saveEveryFiles: Int = VerifyCheckpointStore.defaultSaveEveryFiles,
        saveEverySeconds: TimeInterval = VerifyCheckpointStore.defaultSaveEverySeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.saveEveryFiles = saveEveryFiles
        self.saveEverySeconds = saveEverySeconds
        self.now = now
    }

    /// `Application Support/Uncloud/Verify/<destination key>.json`.
    static func standard(for destination: URL) -> VerifyCheckpointStore {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let folder = support.appending(path: "Uncloud", directoryHint: .isDirectory)
            .appending(path: "Verify", directoryHint: .isDirectory)
        return VerifyCheckpointStore(url: folder.appending(path: NewPhotosContext.destinationKey(for: destination) + ".json"))
    }

    /// The saved checkpoint, or nil when there is none, it can't be read, or its schema is another version.
    func load() -> VerifyCheckpoint? {
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? Self.decoder.decode(VerifyCheckpoint.self, from: data),
              checkpoint.schema == VerifyCheckpoint.schemaVersion else { return nil }
        return checkpoint
    }

    /// Writes the checkpoint atomically, so a crash leaves the old one or the new one.
    func save(_ checkpoint: VerifyCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(checkpoint).write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoString(date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseISO(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(text)")
            }
            return date
        }
        return decoder
    }()

    /// `2026-10-21T10:00:00.000Z`.
    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// The journal's size and head, read from the drive.
enum VerifyJournal {
    /// `.photo-export/exported.tsv`, relative to the destination.
    static let relativePath = ".photo-export/exported.tsv"

    /// The journal's size in bytes. Zero when there is no journal.
    static func size(in destination: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(in: destination).path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// SHA-256 (lowercase hex) of the journal's first `length` bytes. Shorter if the journal is shorter. Nil when it
    /// can't be read.
    static func head(in destination: URL, length: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url(in: destination)) else {
            return length == 0 ? hex(SHA256.hash(data: Data())) : nil
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Int(length))) ?? Data()
        return hex(SHA256.hash(data: data))
    }

    /// The checkpoint's head for a journal of `size` bytes: the first `min(64 KB, size)` bytes.
    static func headOfCurrentJournal(in destination: URL, size: Int64) -> String? {
        head(in: destination, length: min(VerifyCheckpoint.headLength, size))
    }

    static func url(in destination: URL) -> URL {
        destination.appending(path: relativePath)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", Int($0)) }.joined()
    }
}

/// Whether a saved checkpoint may be continued for a destination right now.
enum VerifyCheckpointResumability: Equatable {
    /// No checkpoint: the pass starts from the first item.
    case none
    /// The checkpoint still matches the journal: the pass continues from its `nextItemIndex`.
    case resume(VerifyCheckpoint)
    /// The checkpoint no longer matches the journal, so the pass starts over. The reason is shown to the user.
    case restart(reason: String)
}

extension VerifyCheckpoint {
    static let restartReason = "The export records changed since the last pass, so the check started over."

    /// Decides whether `checkpoint` can be continued: the journal must be at least as long as when it was saved, and its
    /// first `journalBytes` head must still hash to `journalHead`.
    static func resumability(of checkpoint: VerifyCheckpoint?, destination: URL) -> VerifyCheckpointResumability {
        guard let checkpoint else { return .none }
        guard VerifyJournal.size(in: destination) >= checkpoint.journalBytes,
              VerifyJournal.headOfCurrentJournal(in: destination, size: checkpoint.journalBytes) == checkpoint.journalHead
        else {
            return .restart(reason: restartReason)
        }
        return .resume(checkpoint)
    }
}
