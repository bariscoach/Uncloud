import Foundation
import Photos

struct LibraryProgress: Sendable {
    var total: Int
    var exported: Int
    var hasIncompleteRun: Bool
    var previousLayout: FolderLayout?
}

enum PhotoLibrary {
    /// Every photo, video and audio item, oldest first unless `newestFirst`.
    static func allAssets(newestFirst: Bool = false) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(with: fetchOptions(newestFirst: newestFirst))
    }

    private static func fetchOptions(newestFirst: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }

    /// How many selected items there are and how many of them the destination already has.
    static func progress(toward destination: URL, selection: LibrarySelection = .everything) -> LibraryProgress {
        let assets = allAssets()
        let exportedIDs = ExportManifest.exportedIDs(in: destination)
        var exported = 0
        var total = assets.count
        if !exportedIDs.isEmpty || !selection.isEverything {
            assets.enumerateObjects { asset, _, _ in
                let id = asset.localIdentifier
                if !selection.contains(id) {
                    total -= 1
                } else if exportedIDs.contains(id) {
                    exported += 1
                }
            }
        }
        return LibraryProgress(
            total: total,
            exported: exported,
            hasIncompleteRun: ExportManifest.hasIncompleteRun(in: destination),
            previousLayout: ExportManifest.layout(in: destination)
        )
    }
}
