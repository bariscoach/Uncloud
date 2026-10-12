import Photos

/// Which user albums each library item belongs to, as folder-style paths.
struct AlbumIndex: Sendable {
    static let notInAlbumFolder = "Not in an Album"

    private let albumsByIdentifier: [String: [String]]

    private init(albumsByIdentifier: [String: [String]]) {
        self.albumsByIdentifier = albumsByIdentifier
    }

    /// Sorted album paths such as ["Family", "Trips/Rome 2024"]; empty when the item is in no album.
    func albums(for localIdentifier: String) -> [String] {
        albumsByIdentifier[localIdentifier] ?? []
    }

    /// Walks the user's albums and folders. Synchronous; call it off the main actor.
    static func build() -> AlbumIndex {
        var membership: [String: Set<String>] = [:]
        walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), parents: [], into: &membership)
        return AlbumIndex(albumsByIdentifier: membership.mapValues { $0.sorted() })
    }

    private static func walk(
        _ collections: PHFetchResult<PHCollection>,
        parents: [String],
        into membership: inout [String: Set<String>]
    ) {
        // Names are only reserved for folders and albums that appear in the index,
        // so an excluded collection never pushes a visible sibling to "(2)".
        var usedNames: Set<String> = []
        for index in 0..<collections.count {
            let collection = collections.object(at: index)
            if let folder = collection as? PHCollectionList {
                let name = uniqueName(for: folder.localizedTitle, usedNames: &usedNames)
                let children = PHCollection.fetchCollections(in: folder, options: nil)
                walk(children, parents: parents + [name], into: &membership)
            } else if let album = collection as? PHAssetCollection,
                      album.assetCollectionType == .album,
                      album.assetCollectionSubtype != .albumCloudShared {
                let name = uniqueName(for: album.localizedTitle, usedNames: &usedNames)
                let path = (parents + [name]).joined(separator: "/")
                let assets = PHAsset.fetchAssets(in: album, options: nil)
                for assetIndex in 0..<assets.count {
                    membership[assets.object(at: assetIndex).localIdentifier, default: []].insert(path)
                }
            }
        }
    }

    /// A folder name for an album: sanitized, with " (2)", " (3)"… added when `usedNames` already has it.
    static func uniqueName(for title: String?, usedNames: inout Set<String>) -> String {
        let base = sanitized(title)
        var name = base
        var suffix = 2
        while usedNames.contains(name) {
            name = "\(base) (\(suffix))"
            suffix += 1
        }
        usedNames.insert(name)
        return name
    }

    private static func sanitized(_ title: String?) -> String {
        // Tabs and line breaks would corrupt the manifest's tab-separated lines.
        var name = (title ?? "")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while let first = name.first, first == "." || first.isWhitespace {
            name.removeFirst()
        }
        while let last = name.last, last.isWhitespace {
            name.removeLast()
        }
        return name.isEmpty ? "Untitled Album" : name
    }
}
