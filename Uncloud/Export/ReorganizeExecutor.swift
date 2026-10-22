import Darwin
import Foundation

/// Moves a flat backup into `YYYY/MM` folders (R17b), following the plan from `ReorganizePlanner`.
///
/// Safety rules, in the order the code relies on them:
/// - Every move is a `renamex_np` with `RENAME_EXCL` on the same volume. Nothing is copied, nothing is overwritten,
///   and an `EXDEV` stops the run.
/// - The journal (`ReorganizeJournal`) holds the plan before the first move. A batch line is written before each
///   batch, and a `renamed` line before any rename to a name other than the planned one.
/// - A crash can lose at most the `done` lines not yet flushed. Recovery doesn't trust the journal for those: for
///   each planned file it checks which of the two names exists, so every step is idempotent.
/// - A file that is in neither place is skipped and logged. A file present under both names stops the run with
///   both paths, because only an outside change can cause it.
/// - Undo moves the done files back with the same rules, restores companions, restores the manifest with the inverse
///   map and removes the folders the run created when they are empty.
actor ReorganizeExecutor {
    enum Phase: Equatable, Sendable {
        case planning
        case moving(done: Int, total: Int)
        case updatingRecords
        case finished
        case paused
        case failed(String)
    }

    /// Rewrites the manifest's paths (`ExportManifest.relocate` in R17c). The map is `old → new` for a run, `new → old`
    /// for an undo. The journal calls it once per run, after the moves.
    typealias Relocate = @Sendable (_ map: [String: String], _ destination: URL, _ layout: FolderLayout) throws -> Void

    static let batchSize = 500
    static let flushInterval = 200
    static let minimumFreeBytes: Int64 = 50 * 1024 * 1024
    /// Companions larger than this are never read, so they are moved, not deleted.
    static let maxCompanionBytes = 4_096
    static let undoWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let maxRenameAttempts = 1_000

    private(set) var phase: Phase = .planning

    private let destination: URL
    private let fs: any ReorganizeFileSystem
    private let relocate: Relocate
    private let requestedRemoveHelpers: Bool
    private var journal = ReorganizeJournal()
    /// `done` and `skipped` lines, written with the next append. Their effect is already in `journal`.
    private var pendingLines: [String] = []

    /// `relocate` is the manifest phase: `ExportManifest.relocate` unless a test injects another.
    init(
        destination: URL,
        removeHelpers: Bool,
        fs: any ReorganizeFileSystem = LiveReorganizeFileSystem(),
        relocate: @escaping Relocate = { map, destination, layout in
            try ExportManifest.relocate(map, in: destination, layout: layout)
        }
    ) {
        self.destination = destination
        self.requestedRemoveHelpers = removeHelpers
        self.fs = fs
        self.relocate = relocate
    }

    /// The journal waiting in the destination, for gating and launch recovery.
    static func pendingJournal(in destination: URL) -> ReorganizeJournal? {
        ReorganizeJournal.pending(in: destination)
    }

    // MARK: - Entry points

    /// Starts a run: writes the plan to the journal, then moves.
    func start(plan: ReorganizePlanner.Plan) async throws {
        guard !fs.exists(journalURL) else { throw ReorganizeError.alreadyPending }
        try checkNoExportRunning()
        guard ExportManifest.layout(in: destination) == .flat else { throw ReorganizeError.layoutNotFlat }
        let free = try fs.freeBytes(destination)
        guard free >= Self.minimumFreeBytes else { throw ReorganizeError.lowSpace(free) }
        for move in plan.moves where !Self.isSafe(move) {
            throw ReorganizeError.unsafeName(move.new)
        }

        journal = ReorganizeJournal()
        pendingLines = []
        try fs.createDirectory(folderURL)
        let header = ReorganizeJournal.headerLine(
            started: Self.timestamp(Date()),
            removeHelpers: requestedRemoveHelpers,
            count: plan.moves.count
        )
        try appendLines([header] + plan.moves.map(ReorganizeJournal.planLine))
        try appendLines(["planned\t\(plan.moves.count)"])
        try run()
    }

    /// Continues a run from its journal, or finishes an undo that was started. Nothing is moved before `planned`,
    /// so a journal without it is discarded and reported as `notStarted`.
    func resume() async throws {
        guard fs.exists(journalURL) else { throw ReorganizeError.nothingPending }
        journal = ReorganizeJournal.parse(try fs.read(journalURL))
        pendingLines = []
        guard journal.planned || journal.undoStarted else {
            try fs.unlink(journalURL)
            throw ReorganizeError.notStarted
        }
        try run()
    }

    /// Puts the files back. Works on the run in progress (its finished moves) and on the archived journal of a
    /// finished run, for seven days after it finished.
    func undo() async throws {
        if !fs.exists(journalURL) {
            guard let archive = try newestArchive() else { throw ReorganizeError.undoUnavailable }
            try fs.rename(archive, to: journalURL)
        }
        let loaded = ReorganizeJournal.parse(try fs.read(journalURL))
        guard loaded.planned else { throw ReorganizeError.undoUnavailable }
        journal = loaded
        pendingLines = []
        if !journal.undoStarted {
            try appendLines(["undo-started"])
        }
        try run()
    }

    // MARK: - Advancing

    private func run() throws {
        do {
            try advance()
        } catch is CancellationError {
            try? flushPending()
            phase = .paused
            throw CancellationError()
        } catch {
            phase = .failed(Self.describe(error))
            throw error
        }
    }

    private func advance() throws {
        if journal.undoStarted {
            if !journal.undoFinished {
                try undoAdvance()
            } else {
                try removeCreatedFolders()
            }
            try archive(extension: "undone")
            phase = .finished
            return
        }
        if journal.finished {
            try archive(extension: "done")
            phase = .finished
            return
        }
        if !journal.movesFinished {
            try makeFolders()
            try moveAll()
            try flushPending()
            try appendLines(["moves-finished"])
        }
        if !journal.manifestFinished {
            phase = .updatingRecords
            try checkNoExportRunning()
            try relocate(movedMap(), destination, .month)
            try appendLines(["manifest-finished"])
        }
        try appendLines(["finished"])
        try archive(extension: "done")
        phase = .finished
    }

    // MARK: - Moves

    /// Creates the target folders the run needs. Each folder that didn't exist is journaled before it is made, so
    /// undo can remove it again.
    private func makeFolders() throws {
        var needed = Set<String>()
        for entry in journal.entries {
            var prefix = ""
            for part in Self.parent(of: journal.effectiveNew(entry)).split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                needed.insert(prefix)
            }
        }
        for folder in needed.sorted(by: Self.shallowFirst) where !fs.exists(destination.appending(path: folder)) {
            try appendLines(["folder\t\(folder)"])
            try fs.createDirectory(destination.appending(path: folder, directoryHint: .isDirectory))
        }
    }

    private func moveAll() throws {
        let entries = journal.entries.sorted { $0.index < $1.index }
        // A run that already began a batch may find files under either name after a crash, so it checks each one.
        let recovering = journal.batchesStarted
        var root = try fs.list(destination)
        var folders: [String: Set<String>] = [:]
        var start = 0
        while start < entries.count {
            try Task.checkCancellation()
            try checkNoExportRunning()
            let batch = Array(entries[start ..< min(start + Self.batchSize, entries.count)])
            start += batch.count

            let pending = batch.filter { !journal.done.contains($0.index) && !journal.skipped.contains($0.index) }
            if let first = batch.first, let last = batch.last, !pending.isEmpty {
                try appendLines(["batch\t\(first.index)\t\(last.index)"])
            }
            for entry in pending {
                try Task.checkCancellation()
                try moveOne(entry, recovering: recovering, root: &root, folders: &folders)
                if pendingLines.count >= Self.flushInterval {
                    try flushPending()
                }
                phase = .moving(done: journal.done.count, total: entries.count)
            }
            try flushPending()
            root = try fs.list(destination)
            try companions(for: batch, root: root)
        }
    }

    private func moveOne(
        _ entry: ReorganizeJournal.Entry,
        recovering: Bool,
        root: inout [String: BulkDirectoryLister.Entry],
        folders: inout [String: Set<String>]
    ) throws {
        let effective = journal.effectiveNew(entry)
        let oldPresent = Self.isFile(root[entry.old])
        try loadFolder(Self.parent(of: effective), into: &folders)
        let newPresent = folders[Self.parent(of: effective), default: []].contains(Self.name(of: effective))

        if !oldPresent {
            // Already moved (the crash came after the rename) or gone. Only a file that is there counts as done.
            if newPresent {
                journal.done.insert(entry.index)
                pendingLines.append("done\t\(entry.index)")
            } else {
                journal.skipped.insert(entry.index)
                pendingLines.append("skipped\t\(entry.index)")
            }
            return
        }
        if recovering && newPresent {
            throw ReorganizeError.conflict(old: entry.old, new: effective)
        }

        var target = effective
        var attempt = 0
        var taken = folders[Self.parent(of: effective), default: []]
        if newPresent {
            // The planned name was taken after the plan was made: the next free name in the same folder instead.
            target = Self.nextFree(entry.new, attempt: &attempt, taken: taken)
        }
        var moved = false
        var tries = 0
        while !moved {
            tries += 1
            guard tries <= Self.maxRenameAttempts else {
                throw POSIXError(.EEXIST)
            }
            if journal.effectiveNew(entry) != target {
                try appendLines(["renamed\t\(entry.index)\t\(target)"])
            }
            do {
                try fs.rename(destination.appending(path: entry.old), to: destination.appending(path: target))
                moved = true
            } catch let error as POSIXError where error.code == .EEXIST {
                taken.insert(Self.name(of: target))
                target = Self.nextFree(entry.new, attempt: &attempt, taken: taken)
            }
        }

        root[entry.old] = nil
        folders[Self.parent(of: target), default: []].insert(Self.name(of: target))
        journal.done.insert(entry.index)
        pendingLines.append("done\t\(entry.index)")
    }

    /// The companion (`._<old name>`) of each moved file in the batch, once the batch's moves are done. A companion
    /// that holds only the quarantine flag (or nothing) is deleted, and the bytes are journaled first so undo can
    /// restore them. Any other companion moves next to its file as `._<new name>`. Idempotent: it only looks at what
    /// is in the root now.
    private func companions(for batch: [ReorganizeJournal.Entry], root: [String: BulkDirectoryLister.Entry]) throws {
        var intents: [String] = []
        var deletions: [(url: URL, index: Int)] = []
        var moves: [(from: URL, to: String, index: Int)] = []
        let removeHelpers = journal.header?.removeHelpers ?? requestedRemoveHelpers

        for entry in batch where journal.done.contains(entry.index) {
            let name = "._" + entry.old
            guard Self.isFile(root[name]), let info = root[name] else { continue }
            if case .kept? = journal.companions[entry.index] { continue }
            let url = destination.appending(path: name)

            if removeHelpers, info.size <= Self.maxCompanionBytes,
               let data = try? fs.read(url), Self.isDeletable(data) {
                intents.append("companion\t\(entry.index)\tdeleted\t\(data.base64EncodedString())")
                deletions.append((url, entry.index))
            } else {
                let target = Self.companionName(for: journal.effectiveNew(entry))
                intents.append("companion\t\(entry.index)\tmoved\t\(target)")
                moves.append((url, target, entry.index))
            }
        }
        try appendLines(intents)

        for deletion in deletions {
            try fs.unlink(deletion.url)
        }
        var kept: [String] = []
        for move in moves {
            do {
                try fs.rename(move.from, to: destination.appending(path: move.to))
            } catch let error as POSIXError where error.code == .EEXIST {
                kept.append("companion\t\(move.index)\tkept")
            }
        }
        try appendLines(kept)
    }

    // MARK: - Undo

    private func undoAdvance() throws {
        try checkNoExportRunning()
        phase = .moving(done: 0, total: journal.entries.count)
        var root = try fs.list(destination)
        var folders: [String: Set<String>] = [:]
        var inverse: [String: String] = [:]

        for entry in journal.entries.sorted(by: { $0.index < $1.index }) {
            let effective = journal.effectiveNew(entry)
            let wasDone = journal.done.contains(entry.index)
            let oldPresent = Self.isFile(root[entry.old])
            try loadFolder(Self.parent(of: effective), into: &folders)
            let newPresent = folders[Self.parent(of: effective), default: []].contains(Self.name(of: effective))

            if !oldPresent && newPresent {
                do {
                    try fs.rename(destination.appending(path: effective), to: destination.appending(path: entry.old))
                } catch let error as POSIXError where error.code == .EEXIST {
                    throw ReorganizeError.conflict(old: entry.old, new: effective)
                }
                folders[Self.parent(of: effective), default: []].remove(Self.name(of: effective))
                root[entry.old] = BulkDirectoryLister.Entry(name: entry.old, kind: .file, size: 0, modified: 0, isHidden: false)
                inverse[effective] = entry.old
                try restoreCompanion(for: entry)
            } else if oldPresent && newPresent {
                // Both names are taken. For a file this run moved, that's an outside change: stop. For a file it never
                // moved, the planned name was taken by something else and nothing here is ours to touch.
                if wasDone {
                    throw ReorganizeError.conflict(old: entry.old, new: effective)
                }
            } else if oldPresent && wasDone {
                // Restored by an earlier undo. Still in the inverse map, so the manifest is left as it should be.
                inverse[effective] = entry.old
                try restoreCompanion(for: entry)
            }
        }

        try relocate(inverse, destination, .flat)
        try appendLines(["undo-finished"])
        try removeCreatedFolders()
    }

    /// Removes the folders the run created, deepest first. One that still has files in it stays: the owner put
    /// something there after the run.
    private func removeCreatedFolders() throws {
        for folder in journal.folders.sorted(by: Self.deepestFirst) where fs.exists(destination.appending(path: folder)) {
            do {
                try fs.removeEmptyDirectory(destination.appending(path: folder))
            } catch let error as POSIXError where error.code == .ENOTEMPTY {
                continue
            }
        }
    }

    private func restoreCompanion(for entry: ReorganizeJournal.Entry) throws {
        let original = destination.appending(path: "._" + entry.old)
        switch journal.companions[entry.index] {
        case .moved(let target)?:
            let moved = destination.appending(path: target)
            guard fs.exists(moved), !fs.exists(original) else { return }
            do {
                try fs.rename(moved, to: original)
            } catch let error as POSIXError where error.code == .EEXIST {
                throw ReorganizeError.conflict(old: "._" + entry.old, new: target)
            }
        case .deleted(let bytes)?:
            guard !fs.exists(original) else { return }
            do {
                try fs.writeNew(original, bytes)
            } catch let error as POSIXError where error.code == .EEXIST {
                return
            }
        case .kept?, nil:
            return
        }
    }

    // MARK: - Journal writing

    /// Appends lines in one write, after any buffered `done` and `skipped` lines, and folds them into the state.
    private func appendLines(_ lines: [String]) throws {
        let all = pendingLines + lines
        guard !all.isEmpty else { return }
        try fs.append(journalURL, Data((all.joined(separator: "\n") + "\n").utf8))
        pendingLines = []
        for line in lines {
            journal.apply(line)
        }
    }

    private func flushPending() throws {
        try appendLines([])
    }

    /// Moves the journal to `reorganize-<stamp>.<extension>`, the archive kept for history and for undo.
    private func archive(extension ext: String) throws {
        let stamp = Self.stampFormatter().string(from: Date())
        var suffix = 1
        while true {
            let name = suffix == 1 ? "reorganize-\(stamp).\(ext)" : "reorganize-\(stamp)-\(suffix).\(ext)"
            do {
                try fs.rename(journalURL, to: folderURL.appending(path: name))
                return
            } catch let error as POSIXError where error.code == .EEXIST {
                suffix += 1
            }
        }
    }

    /// The newest `.done` archive that is still inside the undo window.
    private func newestArchive() throws -> URL? {
        var best: (url: URL, date: Date)?
        let prefix = "reorganize-"
        for name in try fs.list(folderURL).keys where name.hasPrefix(prefix) && name.hasSuffix(".done") {
            let stamp = String(name.dropFirst(prefix.count).prefix(15))
            guard let date = Self.stampFormatter().date(from: stamp),
                  Date().timeIntervalSince(date) <= Self.undoWindow else { continue }
            if best == nil || date > best!.date {
                best = (folderURL.appending(path: name), date)
            }
        }
        return best?.url
    }

    // MARK: - Helpers

    private var journalURL: URL { ReorganizeJournal.url(in: destination) }
    private var folderURL: URL {
        destination.appending(path: ReorganizeJournal.folderName, directoryHint: .isDirectory)
    }

    private func checkNoExportRunning() throws {
        guard !ExportManifest.hasIncompleteRun(in: destination) else { throw ReorganizeError.exportRunning }
    }

    private func movedMap() -> [String: String] {
        var map: [String: String] = [:]
        for entry in journal.entries where journal.done.contains(entry.index) {
            map[entry.old] = journal.effectiveNew(entry)
        }
        return map
    }

    private func loadFolder(_ folder: String, into folders: inout [String: Set<String>]) throws {
        guard folders[folder] == nil else { return }
        let names = try fs.list(destination.appending(path: folder, directoryHint: .isDirectory))
        folders[folder] = Set(names.keys)
    }

    private static func isSafe(_ move: ReorganizePlanner.Move) -> Bool {
        ExportManifest.isSafeRelativePath(move.old) && !move.old.contains("/")
            && ExportManifest.isSafeRelativePath(move.new) && move.new.contains("/")
            && !move.key.isEmpty && move.key.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isFile(_ entry: BulkDirectoryLister.Entry?) -> Bool {
        guard let entry else { return false }
        if case .file = entry.kind { return true }
        return false
    }

    /// Only a companion the classifier proves holds nothing but the quarantine flag (or nothing) may be deleted.
    private static func isDeletable(_ data: Data) -> Bool {
        switch AppleDouble.classify(data) {
        case .quarantineOnly, .empty: true
        case .keep: false
        }
    }

    /// `._<name>` in the same folder as `path`.
    private static func companionName(for path: String) -> String {
        let folder = parent(of: path)
        return folder.isEmpty ? "._" + name(of: path) : folder + "/._" + name(of: path)
    }

    /// The first `stem (n).ext` in the folder, after `attempt`, that isn't in `taken`.
    private static func nextFree(_ planned: String, attempt: inout Int, taken: Set<String>) -> String {
        let folder = parent(of: planned)
        let name = name(of: planned)
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        while true {
            attempt += 1
            let candidate = ext.isEmpty ? "\(stem) (\(attempt))" : "\(stem) (\(attempt)).\(ext)"
            if !taken.contains(candidate) {
                return folder.isEmpty ? candidate : folder + "/" + candidate
            }
        }
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func shallowFirst(_ a: String, _ b: String) -> Bool {
        let depthA = a.split(separator: "/").count
        let depthB = b.split(separator: "/").count
        return depthA != depthB ? depthA < depthB : a < b
    }

    private static func deepestFirst(_ a: String, _ b: String) -> Bool {
        let depthA = a.split(separator: "/").count
        let depthB = b.split(separator: "/").count
        return depthA != depthB ? depthA > depthB : a > b
    }

    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func describe(_ error: Error) -> String {
        if let reorganize = error as? ReorganizeError {
            return reorganize.description
        }
        if let posix = error as? POSIXError, posix.code == .EXDEV {
            return "The folder spans two drives, so a file can't be moved by rename. Nothing was copied."
        }
        return error.localizedDescription
    }
}

enum ReorganizeError: Error, Equatable, CustomStringConvertible {
    case alreadyPending
    case nothingPending
    case notStarted
    case layoutNotFlat
    case exportRunning
    case lowSpace(Int64)
    case unsafeName(String)
    case conflict(old: String, new: String)
    case undoUnavailable

    var description: String {
        switch self {
        case .alreadyPending:
            "A reorganize is already in progress. Resume it or undo it first."
        case .nothingPending:
            "There is no reorganize to resume."
        case .notStarted:
            "The reorganize had not started, so nothing was moved. It was discarded."
        case .layoutNotFlat:
            "The backup is not in one folder, so there is nothing to reorganize."
        case .exportRunning:
            "An export or check is running. The reorganize stopped and can be resumed later."
        case .lowSpace(let bytes):
            "The drive has \(bytes) bytes free. The reorganize needs at least 50 MB."
        case .unsafeName(let name):
            "The file name \"\(name)\" can't be moved safely."
        case .conflict(let old, let new):
            "\"\(old)\" and \"\(new)\" both exist. The reorganize stopped and changed nothing for this file. Check both."
        case .undoUnavailable:
            "There is no reorganize to undo."
        }
    }
}

/// The few file operations the mover needs. The live one renames with `RENAME_EXCL`. Tests inject faults through it.
protocol ReorganizeFileSystem: Sendable {
    /// Renames without replacing: fails with EEXIST when `to` exists, and with EXDEV across volumes.
    func rename(_ from: URL, to: URL) throws
    func unlink(_ url: URL) throws
    func removeEmptyDirectory(_ url: URL) throws
    /// Creates a folder. An existing folder is not an error.
    func createDirectory(_ url: URL) throws
    /// The entries of a folder by name. A missing folder lists as empty.
    func list(_ folder: URL) throws -> [String: BulkDirectoryLister.Entry]
    func read(_ url: URL) throws -> Data
    /// Creates a new file with `data`, fails with EEXIST when it exists, and syncs it to the disk.
    func writeNew(_ url: URL, _ data: Data) throws
    /// Appends `data` and syncs it to the disk.
    func append(_ url: URL, _ data: Data) throws
    /// True when something (a file, a folder or a link) is at `url`. Doesn't follow links.
    func exists(_ url: URL) -> Bool
    func freeBytes(_ url: URL) throws -> Int64
}

struct LiveReorganizeFileSystem: ReorganizeFileSystem {
    func rename(_ from: URL, to: URL) throws {
        guard renamex_np(from.path(percentEncoded: false), to.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 else {
            throw Self.posixError(errno)
        }
    }

    func unlink(_ url: URL) throws {
        guard Darwin.unlink(url.path(percentEncoded: false)) == 0 else { throw Self.posixError(errno) }
    }

    func removeEmptyDirectory(_ url: URL) throws {
        guard rmdir(url.path(percentEncoded: false)) == 0 else { throw Self.posixError(errno) }
    }

    func createDirectory(_ url: URL) throws {
        guard mkdir(url.path(percentEncoded: false), 0o755) == 0 || errno == EEXIST else {
            throw Self.posixError(errno)
        }
    }

    func list(_ folder: URL) throws -> [String: BulkDirectoryLister.Entry] {
        let entries: [BulkDirectoryLister.Entry]
        do {
            entries = try BulkDirectoryLister.list(folder)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return [:]
        }
        var result: [String: BulkDirectoryLister.Entry] = [:]
        for entry in entries {
            result[entry.name] = entry
        }
        return result
    }

    func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeNew(_ url: URL, _ data: Data) throws {
        try Self.write(url, data, flags: O_WRONLY | O_CREAT | O_EXCL)
    }

    func append(_ url: URL, _ data: Data) throws {
        try Self.write(url, data, flags: O_WRONLY | O_CREAT | O_APPEND)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    func freeBytes(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path(percentEncoded: false))
        guard let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw POSIXError(.EIO)
        }
        return free
    }

    private static func write(_ url: URL, _ data: Data, flags: Int32) throws {
        let descriptor = open(url.path(percentEncoded: false), flags, 0o644)
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError(errno) }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
