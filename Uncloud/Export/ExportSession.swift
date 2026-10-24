import CryptoKit
import Foundation

/// The record of one export run, saved in the destination's `.photo-export/sessions/` folder so the
/// export history travels with the drive. A run that is resumed automatically, or resumed by hand soon
/// after it stopped, is a new attempt in the same chain (`chainID`), not a rewrite of the first file.
///
/// Holds no Apple ID, no asset IDs and no paths outside the destination. Failures list file names only.
struct ExportSession: Codable, Identifiable, Equatable, Sendable {
    /// The file layout this build writes. Files with a higher schema are shown read-only.
    static let currentSchema = 1

    var schema: Int
    var id: UUID
    /// Equal to `id` for the first attempt of a chain.
    var chainID: UUID
    /// 1-based within the chain.
    var attempt: Int
    var kind: Kind
    var trigger: Trigger
    var startedAt: Date
    /// The heartbeat, written at every checkpoint.
    var updatedAt: Date
    var endedAt: Date?
    /// For example "0.1.4 (14)".
    var appVersion: String
    /// One per app launch: tells "mine, still running" from "orphaned by a quit or a restart".
    var launchID: UUID
    /// Nil when the file names a source this build doesn't know. The name is kept and written back unchanged.
    var source: LibrarySource? {
        get { sourceValue.known }
        set { sourceValue = RawEnum(newValue) }
    }
    /// Pseudonymous, see `accountHash(appleID:)`. Nil for the Photos library on this Mac.
    var account: String?
    /// Nil when the file names a layout this build doesn't know, such as "flat" read by an older Uncloud.
    /// The name is kept and written back unchanged.
    var layout: FolderLayout? {
        get { layoutValue.known }
        set { layoutValue = RawEnum(newValue) }
    }
    var writesSidecars: Bool
    var selection: SelectionSummary
    var libraryCount: Int?
    var driveCheck: DriveCheckSummary?
    var continuation: Continuation?
    var counts: Counts
    var result: Result
    /// Set when this attempt ended into a scheduled automatic resume.
    var autoResume: AutoResumeNote?
    /// The first 50 failures, by file name and reason. The total is in `counts.failed`.
    var failures: [Failure]

    /// The layout's stored name, including one this build doesn't know.
    var layoutName: String { layoutValue.raw }
    /// The source's stored name, including one this build doesn't know.
    var sourceName: String { sourceValue.raw }

    /// The stored source and layout: a known case, or the raw name of one this build doesn't know.
    private var sourceValue: RawEnum<LibrarySource>
    private var layoutValue: RawEnum<FolderLayout>

    /// A new run. `chainID` defaults to `id`, which is right for the first attempt.
    init(
        id: UUID = UUID(),
        chainID: UUID? = nil,
        attempt: Int = 1,
        kind: Kind = .export,
        trigger: Trigger,
        startedAt: Date,
        appVersion: String,
        launchID: UUID,
        source: LibrarySource,
        account: String? = nil,
        layout: FolderLayout,
        writesSidecars: Bool,
        selection: SelectionSummary
    ) {
        schema = Self.currentSchema
        self.id = id
        self.chainID = chainID ?? id
        self.attempt = attempt
        self.kind = kind
        self.trigger = trigger
        self.startedAt = startedAt
        updatedAt = startedAt
        endedAt = nil
        self.appVersion = appVersion
        self.launchID = launchID
        sourceValue = RawEnum(source)
        self.account = account
        layoutValue = RawEnum(layout)
        self.writesSidecars = writesSidecars
        self.selection = selection
        libraryCount = nil
        driveCheck = nil
        continuation = nil
        counts = Counts()
        result = Result(status: .running)
        autoResume = nil
        failures = []
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case schema, id, chainID, attempt, kind, trigger, startedAt, updatedAt, endedAt, appVersion, launchID
        case source, account, layout, writesSidecars, selection, libraryCount, driveCheck, continuation
        case counts, result, autoResume, failures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        id = try container.decode(UUID.self, forKey: .id)
        chainID = try container.decode(UUID.self, forKey: .chainID)
        attempt = try container.decode(Int.self, forKey: .attempt)
        kind = try container.decode(Kind.self, forKey: .kind)
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        launchID = try container.decode(UUID.self, forKey: .launchID)
        sourceValue = try container.decode(RawEnum<LibrarySource>.self, forKey: .source)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        layoutValue = try container.decode(RawEnum<FolderLayout>.self, forKey: .layout)
        writesSidecars = try container.decode(Bool.self, forKey: .writesSidecars)
        selection = try container.decode(SelectionSummary.self, forKey: .selection)
        libraryCount = try container.decodeIfPresent(Int.self, forKey: .libraryCount)
        driveCheck = try container.decodeIfPresent(DriveCheckSummary.self, forKey: .driveCheck)
        continuation = try container.decodeIfPresent(Continuation.self, forKey: .continuation)
        counts = try container.decode(Counts.self, forKey: .counts)
        result = try container.decode(Result.self, forKey: .result)
        autoResume = try container.decodeIfPresent(AutoResumeNote.self, forKey: .autoResume)
        failures = try container.decode([Failure].self, forKey: .failures)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(chainID, forKey: .chainID)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(kind, forKey: .kind)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(launchID, forKey: .launchID)
        try container.encode(sourceValue, forKey: .source)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encode(layoutValue, forKey: .layout)
        try container.encode(writesSidecars, forKey: .writesSidecars)
        try container.encode(selection, forKey: .selection)
        try container.encodeIfPresent(libraryCount, forKey: .libraryCount)
        try container.encodeIfPresent(driveCheck, forKey: .driveCheck)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encode(counts, forKey: .counts)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(autoResume, forKey: .autoResume)
        try container.encode(failures, forKey: .failures)
    }

    /// True for a file written by a newer Uncloud. It is listed, but never rewritten.
    var isReadOnly: Bool {
        schema > Self.currentSchema
    }

    /// True once the run has ended, whatever the outcome.
    var isFinished: Bool {
        result.status != .running
    }

    /// The pseudonymous account label stored in `account`: the first 16 hex digits of a SHA-256 over
    /// "uncloud-account-v1:" and the trimmed, lowercased Apple ID. It lets History say "a different iCloud
    /// account" without storing the ID. The label can be guessed from a known address, which is accepted
    /// for a file on the user's own drive.
    static func accountHash(appleID: String) -> String {
        let normalized = "uncloud-account-v1:" + appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    enum Kind: String, Codable, Equatable, Sendable {
        case export
        /// No longer started by the app. Kept so History still decodes the verify runs saved by earlier versions.
        case verify
        case driveCheck
    }

    enum Trigger: String, Codable, Equatable, Sendable {
        case manual
        case exportAll
        case automaticBackup
        case autoResume
        case resume
    }

    enum Status: String, Codable, Equatable, Sendable {
        case running
        case completed
        case completedWithFailures
        case cancelled
        case failed
        case interrupted
    }

    struct Result: Codable, Equatable, Sendable {
        var status: Status
        /// For people, such as "Apple is limiting downloads".
        var reason: String?
        /// Whether the run may be retried automatically.
        var retryable: Bool?
    }

    enum SelectionKind: String, Codable, Equatable, Sendable {
        case everything
        case only
        case allExcept
    }

    /// What was selected. Never the IDs themselves.
    struct SelectionSummary: Codable, Equatable, Sendable {
        var kind: SelectionKind
        var count: Int
    }

    struct DriveCheckSummary: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Equatable, Sendable {
            case quick
            case full
        }

        var onDrive: Int
        var toGo: Int
        var missing: Int
        var damaged: Int
        var setAside: Int
        var untracked: Int
        var mode: Mode
        var seconds: Double
    }

    struct Continuation: Codable, Equatable, Sendable {
        enum Strategy: String, Codable, Equatable, Sendable {
            case fullWalk
            case fromRank
            case selection
            /// Only the new photos at the top of the library (the routine quick update).
            case quick
        }

        var strategy: Strategy
        var startRank: Int?
        /// Why the run walked everything after all, when it planned to continue from a rank.
        var fallbackReason: String?
    }

    struct Counts: Codable, Equatable, Sendable {
        var exported = 0
        var skipped = 0
        var failed = 0
        var bytesWritten = 0
    }

    struct Failure: Codable, Equatable, Sendable {
        var name: String
        var reason: String
    }

    struct AutoResumeNote: Codable, Equatable, Sendable {
        var attempt: Int
        var resumeAt: Date
    }
}

// Both enums are stored by their raw value, so the file holds the same strings the rest of the app uses.
extension FolderLayout: Codable {}
extension LibrarySource: Codable {}

/// A string-backed enum value read from a file: the case when this build knows it, else the raw string,
/// which is written back unchanged. So a session from a newer Uncloud (such as layout "flat" read by an
/// older one) still decodes, and rewriting it, as the interrupted sweep does, doesn't lose the value.
struct RawEnum<Value: RawRepresentable & Sendable & Equatable>: Codable, Equatable, Sendable where Value.RawValue == String {
    let raw: String

    init(_ value: Value?) {
        raw = value?.rawValue ?? ""
    }

    var known: Value? {
        Value(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
