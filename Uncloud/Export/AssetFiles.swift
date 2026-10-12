import Foundation
import Photos

/// The files exported for one library item: its originals (including RAW
/// pairs and Live Photo videos) plus the edited rendition when there is one.
struct AssetFiles {
    struct Item {
        let resource: PHAssetResource
        let filename: String
    }

    private static let originalTypes: Set<PHAssetResourceType> = [
        .photo, .video, .audio, .alternatePhoto, .pairedVideo,
    ]
    private static let editedTypes: Set<PHAssetResourceType> = [
        .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo,
    ]

    let displayName: String
    let items: [Item]

    init(asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        let originals = resources.filter { Self.originalTypes.contains($0.type) }
        let primary = originals.first { [.photo, .video, .audio].contains($0.type) } ?? originals.first
        let primaryName = primary.map { Self.sanitized($0.originalFilename) } ?? "Untitled"
        let baseName = (primaryName as NSString).deletingPathExtension

        var items = originals.map { Item(resource: $0, filename: Self.sanitized($0.originalFilename)) }
        for resource in resources where Self.editedTypes.contains(resource.type) {
            let ext = (resource.originalFilename as NSString).pathExtension
            let name = ext.isEmpty ? "\(baseName) (Edited)" : "\(baseName) (Edited).\(ext)"
            items.append(Item(resource: resource, filename: name))
        }

        displayName = primaryName
        self.items = items
    }

    private static func sanitized(_ filename: String) -> String {
        // Tabs and line breaks would corrupt the manifest's tab-separated lines.
        var name = filename.components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        return name.isEmpty ? "Untitled" : name
    }
}
