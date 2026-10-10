import Foundation
import Photos

struct LibraryProgress: Sendable {
    var total: Int
    var exported: Int
    var hasIncompleteRun: Bool
}

enum PhotoLibrary {
    /// Every photo, video and audio item, oldest first.
    static func allAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return PHAsset.fetchAssets(with: options)
    }

    static func progress(toward destination: URL) -> LibraryProgress {
        let assets = allAssets()
        let exportedIDs = ExportManifest.exportedIDs(in: destination)
        var exported = 0
        if !exportedIDs.isEmpty {
            assets.enumerateObjects { asset, _, _ in
                if exportedIDs.contains(asset.localIdentifier) {
                    exported += 1
                }
            }
        }
        return LibraryProgress(
            total: assets.count,
            exported: exported,
            hasIncompleteRun: ExportManifest.hasIncompleteRun(in: destination)
        )
    }
}
