import Foundation

/// The reorganize journal (R17b): `.photo-export/reorganize.journal`, UTF-8, tab-separated, append-only.
///
/// Lines, in the order the executor writes them:
/// - `uncloud-reorganize<TAB>1<TAB>started<TAB>flat<TAB>month<TAB>count<TAB>removeHelpers(0|1)` (header)
/// - `plan<TAB>index<TAB>old<TAB>new<TAB>key`, one per move
/// - `planned<TAB>count`: written after the header and the plan. No move happens before it.
/// - `folder<TAB>relative folder`: a folder the run created (undo removes it again when it is empty)
/// - `batch<TAB>first<TAB>last`: written before a batch of moves starts
/// - `renamed<TAB>index<TAB>relative path`: the name a move is about to use when the planned name was taken.
///   Written before the rename, so a crash can't lose where the file went.
/// - `done<TAB>index`, `skipped<TAB>index`
/// - `companion<TAB>index<TAB>kept` | `companion<TAB>index<TAB>moved<TAB>relative path` (written before the rename)
///   | `companion<TAB>index<TAB>deleted<TAB>base64 bytes` (written before the unlink, so Undo can put it back)
/// - `moves-finished`, `manifest-finished`, `finished`
/// - `undo-started`, `undo-finished`
///
/// Readers skip a partial last line and any line they don't know. Journal state is a fold over the lines: the last
/// `renamed` or `companion` line for an index wins.
struct ReorganizeJournal: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        var started: String
        var removeHelpers: Bool
    }

    struct Entry: Equatable, Sendable {
        var index: Int
        /// The root name before the move. Never contains `/`.
        var old: String
        /// The planned relative path after the move, such as `2024/07/IMG_1.HEIC`.
        var new: String
        var key: String
    }

    enum Companion: Equatable, Sendable {
        case kept
        case moved(String)
        case deleted(Data)
    }

    static let fileName = "reorganize.journal"
    static let folderName = ".photo-export"
    static let formatVersion = "1"
    static let headerTag = "uncloud-reorganize"

    var header: Header?
    var entries: [Entry] = []
    var folders: [String] = []
    var planned = false
    var batchesStarted = false
    var renamed: [Int: String] = [:]
    var done: Set<Int> = []
    var skipped: Set<Int> = []
    var companions: [Int: Companion] = [:]
    var movesFinished = false
    var manifestFinished = false
    var finished = false
    var undoStarted = false
    var undoFinished = false

    /// Where the file of `entry` is meant to be now: the last rename intent, else the planned path.
    func effectiveNew(_ entry: Entry) -> String {
        renamed[entry.index] ?? entry.new
    }

    /// Reads a whole journal, without a partial last line.
    static func parse(_ data: Data) -> ReorganizeJournal {
        var journal = ReorganizeJournal()
        for line in ManifestLines.lines(in: data).lines {
            journal.apply(line)
        }
        return journal
    }

    /// The header line for a new journal.
    static func headerLine(started: String, removeHelpers: Bool, count: Int) -> String {
        [headerTag, formatVersion, started, FolderLayout.flat.rawValue, FolderLayout.month.rawValue,
         String(count), removeHelpers ? "1" : "0"].joined(separator: "\t")
    }

    static func planLine(_ move: ReorganizePlanner.Move) -> String {
        ["plan", String(move.index), move.old, move.new, move.key].joined(separator: "\t")
    }

    /// Folds one line into the state. Unknown and malformed lines are ignored.
    mutating func apply(_ line: String) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let kind = fields.first else { return }
        switch kind {
        case ReorganizeJournal.headerTag:
            guard fields.count >= 7, fields[1] == Self.formatVersion else { return }
            header = Header(started: fields[2], removeHelpers: fields[6] == "1")
        case "plan":
            guard fields.count == 5, let index = Int(fields[1]) else { return }
            entries.append(Entry(index: index, old: fields[2], new: fields[3], key: fields[4]))
        case "folder":
            guard fields.count == 2 else { return }
            folders.append(fields[1])
        case "planned":
            planned = true
        case "batch":
            batchesStarted = true
        case "renamed":
            guard fields.count == 3, let index = Int(fields[1]) else { return }
            renamed[index] = fields[2]
        case "done":
            guard fields.count == 2, let index = Int(fields[1]) else { return }
            done.insert(index)
        case "skipped":
            guard fields.count == 2, let index = Int(fields[1]) else { return }
            skipped.insert(index)
        case "companion":
            guard fields.count >= 3, let index = Int(fields[1]) else { return }
            switch fields[2] {
            case "kept":
                companions[index] = .kept
            case "moved" where fields.count == 4:
                companions[index] = .moved(fields[3])
            case "deleted" where fields.count == 4:
                if let bytes = Data(base64Encoded: fields[3]) { companions[index] = .deleted(bytes) }
            default:
                return
            }
        case "moves-finished":
            movesFinished = true
        case "manifest-finished":
            manifestFinished = true
        case "finished":
            finished = true
        case "undo-started":
            undoStarted = true
        case "undo-finished":
            undoFinished = true
        default:
            return
        }
    }

    /// The journal in the destination, when one is waiting: a run that didn't finish, or an undo that didn't finish.
    /// A finished run whose journal hasn't been archived yet is not pending.
    static func pending(in destination: URL) -> ReorganizeJournal? {
        let url = destination.appending(path: folderName, directoryHint: .isDirectory).appending(path: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let journal = parse(data)
        guard !journal.finished || journal.undoStarted else { return nil }
        return journal
    }

    static func url(in destination: URL) -> URL {
        destination.appending(path: folderName, directoryHint: .isDirectory).appending(path: fileName)
    }
}
