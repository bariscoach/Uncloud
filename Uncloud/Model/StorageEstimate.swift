import Foundation

/// About how much space exporting the selected items takes.
struct StorageEstimate: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        /// iCloud: the sizes of this many items are known, and their average stands in for the rest.
        case sampled(Int)
        /// iCloud: every item's size is known from a scan of the library.
        case scanned
        /// Photos library: estimated from each item's dimensions and length (`PhotoSizeHeuristic`).
        case heuristic
    }

    var bytes: Int64
    /// True when every selected item's size is known exactly.
    var isExact: Bool
    var basis: Basis

    /// "412 GB", or "about 412 GB" when it's an estimate.
    var formatted: String {
        (isExact ? "" : "about ") + Self.format(bytes)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The export size of each item of one library, by ID, and their sum. Selected bytes come from it
/// without walking the library again: everything minus the excluded items, or the sum of the included.
struct AssetSizeTable: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Sizes iCloud reports.
        case measured
        /// Sizes estimated by `PhotoSizeHeuristic`.
        case heuristic
    }

    /// A walk of the library in progress, kept (and saved) across interruptions until it reaches
    /// the end, so that its end can tell which items it saw.
    struct Walk: Equatable, Sendable {
        /// Where it started: 0 for a pass over the whole library, or just before the old end when
        /// the library grew.
        var start: Int
        /// The library's size while walking; -1 until the first page reports it.
        var libraryCount: Int
        /// Every item the walk has seen, with a size or without.
        var seen: Set<String> = []
        /// False once the library's size changed during the walk: offsets shifted, so the walk may
        /// have skipped items, and only a walk from the start can be trusted again.
        var isValid = true
    }

    /// The selected part of the table.
    struct Sum: Equatable, Sendable {
        var bytes: Int64
        /// Selected items whose size the table has.
        var known: Int
        /// Selected items it doesn't have, such as items a scan hasn't reached yet.
        var unknown: Int
    }

    var kind: Kind
    private(set) var sizes: [String: Int64] = [:]
    private(set) var total: Int64 = 0
    /// The library's size when the table was last brought up to date.
    var libraryCount = 0
    /// How many items, from the oldest in icloudpd's order, a scan has covered.
    var scannedThrough = 0
    /// Every item was covered by a scan that reached the end of the library.
    var isComplete = false
    /// The walk in progress, if any.
    var walk: Walk?

    init(kind: Kind) {
        self.kind = kind
    }

    var knownCount: Int { sizes.count }

    var averageSize: Int64? {
        knownCount > 0 ? total / Int64(knownCount) : nil
    }

    func size(of id: String) -> Int64? {
        sizes[id]
    }

    mutating func reserveCapacity(_ count: Int) {
        sizes.reserveCapacity(count)
    }

    mutating func set(_ size: Int64, for id: String) {
        let size = max(0, size)
        if let old = sizes.updateValue(size, forKey: id) {
            total -= old
        }
        total += size
    }

    mutating func merge(_ newSizes: [String: Int64]) {
        for (id, size) in newSizes {
            set(size, for: id)
        }
    }

    /// Adds the sizes of items the table doesn't have yet.
    mutating func mergeMissing(_ newSizes: [String: Int64]) {
        for (id, size) in newSizes where sizes[id] == nil {
            set(size, for: id)
        }
    }

    /// Forgets items that aren't in `ids`, such as items deleted since an earlier scan.
    mutating func keepOnly(_ ids: Set<String>) {
        for (id, size) in sizes where !ids.contains(id) {
            sizes[id] = nil
            total -= size
        }
    }

    /// The selected items' bytes in a library of `libraryCount` items. Costs one lookup per
    /// excluded (allExcept) or included (only) ID, never a walk of the whole table.
    func sum(for selection: LibrarySelection, libraryCount: Int) -> Sum {
        let selectedCount = selection.selectedCount(total: libraryCount)
        var bytes: Int64 = 0
        var known = 0
        switch selection {
        case .allExcept(let excluded):
            bytes = total
            known = knownCount
            for id in excluded {
                if let size = sizes[id] {
                    bytes -= size
                    known -= 1
                }
            }
        case .only(let ids):
            for id in ids {
                if let size = sizes[id] {
                    bytes += size
                    known += 1
                }
            }
        }
        return Sum(bytes: bytes, known: known, unknown: max(0, selectedCount - known))
    }

    /// The estimate for a selection: known sizes, plus the average for the rest. Nil when nothing
    /// is known yet and something is selected.
    func estimate(for selection: LibrarySelection, libraryCount: Int) -> StorageEstimate? {
        let sum = sum(for: selection, libraryCount: libraryCount)
        var bytes = sum.bytes
        if sum.unknown > 0 {
            guard let average = averageSize else { return nil }
            bytes += average * Int64(sum.unknown)
        }
        switch kind {
        case .heuristic:
            return StorageEstimate(bytes: bytes, isExact: false, basis: .heuristic)
        case .measured:
            if isComplete {
                return StorageEstimate(bytes: bytes, isExact: sum.unknown == 0, basis: .scanned)
            }
            if sum.unknown == 0, sum.known == 0 {
                // Nothing selected.
                return StorageEstimate(bytes: 0, isExact: true, basis: .sampled(knownCount))
            }
            return StorageEstimate(bytes: bytes, isExact: false, basis: .sampled(knownCount))
        }
    }

    // MARK: - File format

    private static let magic = "uncloud-sizes"

    /// A header line (`uncloud-sizes 2 kind libraryCount scannedThrough complete walk`, where `walk`
    /// is `-` or `start,libraryCount,valid`), then one `bytes<TAB>seen<TAB>id` line per item, where
    /// `seen` is 1 for items the walk has seen and `bytes` is `-` for a seen item without a size:
    /// about 50 bytes per item. Version 1 files (`bytes<TAB>id`, no walk) still load.
    func encoded() -> Data {
        let walkField = walk.map { "\($0.start),\($0.libraryCount),\($0.isValid ? 1 : 0)" } ?? "-"
        var text = "\(Self.magic) 2 \(kind.rawValue) \(libraryCount) \(scannedThrough) \(isComplete ? 1 : 0) \(walkField)\n"
        text.reserveCapacity(text.utf8.count + sizes.count * 50)
        let seen = walk?.seen ?? []
        for (id, size) in sizes {
            text += "\(size)\t\(seen.contains(id) ? 1 : 0)\t\(id)\n"
        }
        for id in seen where sizes[id] == nil {
            text += "-\t1\t\(id)\n"
        }
        return Data(text.utf8)
    }

    init?(decoding data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        guard let header = lines.popFirst() else { return nil }
        let fields = header.split(separator: " ")
        guard fields.count >= 6, fields[0] == Self.magic, let version = Int(fields[1]),
              version == 1 && fields.count == 6 || version == 2 && fields.count == 7,
              let kind = Kind(rawValue: String(fields[2])),
              let libraryCount = Int(fields[3]), let scannedThrough = Int(fields[4]) else { return nil }
        self.init(kind: kind)
        self.libraryCount = libraryCount
        self.scannedThrough = scannedThrough
        isComplete = fields[5] == "1"
        if version == 2, fields[6] != "-" {
            let parts = fields[6].split(separator: ",")
            guard parts.count == 3, let start = Int(parts[0]), let count = Int(parts[1]) else { return nil }
            walk = Walk(start: start, libraryCount: count, isValid: parts[2] == "1")
        }
        sizes.reserveCapacity(lines.count)
        for line in lines {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            var rest = line[line.index(after: tab)...]
            var isSeen = false
            if version == 2 {
                guard let flagEnd = rest.firstIndex(of: "\t") else { continue }
                isSeen = rest[..<flagEnd] == "1"
                rest = rest[rest.index(after: flagEnd)...]
            }
            let id = String(rest)
            guard !id.isEmpty else { continue }
            if isSeen {
                walk?.seen.insert(id)
            }
            if let size = Int64(line[..<tab]) {
                set(size, for: id)
            }
        }
    }
}

/// The Backup pane's Space row, as plain text, so each case can be tested without a view.
enum SpaceRowText {
    /// "About 3.92 TB to export · 2.01 TB free" once the drive has backed-up photos, "Nothing to export · 2.01 TB free"
    /// when nothing is left. With none backed up (a first export, where the whole selection is what's needed), or
    /// without `needed`, "About 3.92 TB needed · 2.01 TB free". Nil when there's no estimate to show.
    static func value(estimateText: String?, hasEstimate: Bool, backedUp: Bool, needed: Int64?, free: Int64?) -> String? {
        var text: String
        if backedUp, let needed {
            text = needed == 0 ? "Nothing to export" : "About \(StorageEstimate.format(needed)) to export"
        } else if let estimateText {
            let sentence = estimateText.prefix(1).uppercased() + estimateText.dropFirst()
            text = hasEstimate ? "\(sentence) needed" : sentence
        } else {
            return nil
        }
        if let free {
            text += " · \(StorageEstimate.format(free)) free"
        }
        return text
    }
}

/// Whether the export fits on the destination's volume.
enum StorageCheck {
    /// The part of `estimate` still to copy, when `exported` of `selected` items are already in the
    /// destination. Item sizes differ, so this scales by count and is approximate.
    static func remainingBytes(of estimate: StorageEstimate, selected: Int, exported: Int) -> Int64 {
        guard selected > 0, exported > 0 else { return estimate.bytes }
        let remaining = max(0, selected - exported)
        return Int64((Double(estimate.bytes) * Double(remaining) / Double(selected)).rounded(.up))
    }

    /// A warning when `needed` bytes don't fit in `free`, or nil when they do or either is unknown.
    static func warning(needed: Int64?, isExact: Bool, free: Int64?, destinationName: String) -> String? {
        guard let needed, let free, needed > free else { return nil }
        let amount = (isExact ? "" : "about ") + StorageEstimate.format(needed)
        return "This needs \(amount), but “\(destinationName)” has \(StorageEstimate.format(max(0, free))) free."
    }

    /// The space the volume holding `url` has for new files, or nil when it can't be read.
    static func freeBytes(at url: URL) -> Int64? {
        var url = url
        // Resource values are cached per URL; free space must be read fresh each time.
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}
