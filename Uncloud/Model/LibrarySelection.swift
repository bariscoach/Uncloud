import CryptoKit
import Foundation

/// Which library items an export includes: everything except some IDs, or only some IDs.
/// `allExcept` keeps including items added to the library later; `only` never grows by itself.
///
/// IDs are `PHAsset.localIdentifier` for the Photos library and the iCloud asset ID
/// (pyicloud_ipd's `PhotoAsset.id`) for iCloud Photos.
enum LibrarySelection: Codable, Equatable, Sendable {
    case allExcept(Set<String>)
    case only(Set<String>)

    /// The whole library, including anything added later.
    static let everything = LibrarySelection.allExcept([])

    /// True for `allExcept` with nothing excluded: exports run exactly as they did before selection existed.
    var isEverything: Bool {
        if case .allExcept(let excluded) = self { excluded.isEmpty } else { false }
    }

    /// True when nothing at all is selected.
    var isNothing: Bool {
        if case .only(let ids) = self { ids.isEmpty } else { false }
    }

    func contains(_ id: String) -> Bool {
        switch self {
        case .allExcept(let excluded): !excluded.contains(id)
        case .only(let ids): ids.contains(id)
        }
    }

    mutating func toggle(_ id: String) {
        if contains(id) {
            deselect([id])
        } else {
            select([id])
        }
    }

    mutating func select<S: Sequence>(_ ids: S) where S.Element == String {
        switch self {
        case .allExcept(var excluded):
            excluded.subtract(ids)
            self = .allExcept(excluded)
        case .only(var selected):
            selected.formUnion(ids)
            self = .only(selected)
        }
    }

    mutating func deselect<S: Sequence>(_ ids: S) where S.Element == String {
        switch self {
        case .allExcept(var excluded):
            excluded.formUnion(ids)
            self = .allExcept(excluded)
        case .only(var selected):
            selected.subtract(ids)
            self = .only(selected)
        }
    }

    /// The selection without items that no longer exist, such as ones just deleted from iCloud. Removing them from
    /// an `allExcept` exclusion keeps `selectedCount` right, since that count subtracts the excluded IDs.
    func forgetting<S: Sequence>(_ ids: S) -> LibrarySelection where S.Element == String {
        let ids = Set(ids)
        return switch self {
        case .allExcept(let excluded): .allExcept(excluded.subtracting(ids))
        case .only(let selected): .only(selected.subtracting(ids))
        }
    }

    mutating func selectAll() {
        self = .everything
    }

    mutating func deselectAll() {
        self = .only([])
    }

    /// How many of a library of `total` items are selected. For `allExcept` this assumes every
    /// excluded ID is still in the library, so it can undercount after items are deleted.
    func selectedCount(total: Int) -> Int {
        switch self {
        case .allExcept(let excluded): max(0, total - excluded.count)
        case .only(let ids): min(total, ids.count)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case mode, ids
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ids = try container.decode(Set<String>.self, forKey: .ids)
        switch try container.decode(String.self, forKey: .mode) {
        case "allExcept":
            self = .allExcept(ids)
        case "only":
            self = .only(ids)
        case let mode:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Unknown mode \(mode)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allExcept(let ids):
            try container.encode("allExcept", forKey: .mode)
            try container.encode(ids.sorted(), forKey: .ids)
        case .only(let ids):
            try container.encode("only", forKey: .mode)
            try container.encode(ids.sorted(), forKey: .ids)
        }
    }
}

/// Saves one selection per source and account as JSON in
/// `Application Support/<bundle id>/selections/`. The Apple ID is hashed in the file name.
struct LibrarySelectionStore: Sendable {
    let directory: URL

    init(directory: URL = LibrarySelectionStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "Uncloud"
        return support.appending(path: identifier).appending(path: "selections", directoryHint: .isDirectory)
    }

    /// Where the selection for a source lives; `account` is the Apple ID for iCloud and ignored otherwise.
    func fileURL(source: LibrarySource, account: String?) -> URL {
        var name = source.rawValue
        if source == .iCloud {
            let normalized = (account ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let digest = SHA256.hash(data: Data(normalized.utf8))
            name += "-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        }
        return directory.appending(path: name + ".json")
    }

    /// The saved selection, or everything when none was saved or the file can't be read.
    func load(source: LibrarySource, account: String?) -> LibrarySelection {
        guard let data = try? Data(contentsOf: fileURL(source: source, account: account)),
              let selection = try? JSONDecoder().decode(LibrarySelection.self, from: data) else {
            return .everything
        }
        return selection
    }

    func save(_ selection: LibrarySelection, source: LibrarySource, account: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(source: source, account: account)
        if selection.isEverything {
            // The default needs no file.
            try? FileManager.default.removeItem(at: url)
            return
        }
        try JSONEncoder().encode(selection).write(to: url, options: .atomic)
    }
}
