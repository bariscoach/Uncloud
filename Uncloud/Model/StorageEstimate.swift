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

    /// A header line (`uncloud-sizes 1 kind libraryCount scannedThrough complete`), then one
    /// `bytes<TAB>id` line per item: about 50 bytes per item.
    func encoded() -> Data {
        var text = "\(Self.magic) 1 \(kind.rawValue) \(libraryCount) \(scannedThrough) \(isComplete ? 1 : 0)\n"
        text.reserveCapacity(text.utf8.count + sizes.count * 50)
        for (id, size) in sizes {
            text += "\(size)\t\(id)\n"
        }
        return Data(text.utf8)
    }

    init?(decoding data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        guard let header = lines.popFirst() else { return nil }
        let fields = header.split(separator: " ")
        guard fields.count == 6, fields[0] == Self.magic, fields[1] == "1",
              let kind = Kind(rawValue: String(fields[2])),
              let libraryCount = Int(fields[3]), let scannedThrough = Int(fields[4]) else { return nil }
        self.init(kind: kind)
        self.libraryCount = libraryCount
        self.scannedThrough = scannedThrough
        isComplete = fields[5] == "1"
        sizes.reserveCapacity(lines.count)
        for line in lines {
            guard let tab = line.firstIndex(of: "\t"), let size = Int64(line[..<tab]) else { continue }
            let id = line[line.index(after: tab)...]
            guard !id.isEmpty else { continue }
            set(size, for: String(id))
        }
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
