import Foundation
import Photos

/// Estimates how many bytes exporting a Photos library item writes. PhotoKit has no public file
/// size, so this works from what `PHAsset` exposes: the media type, pixel dimensions, duration,
/// whether it's a Live Photo and whether it was edited. It counts what `AssetFiles` exports: the
/// original, the Live Photo movie, and the edited rendition of an edited item. The constants lean
/// high, so the estimate is more likely to be above the real size than below it.
enum PhotoSizeHeuristic {
    /// Bytes per pixel of a photo. iPhone HEIC runs about 0.15–0.35, camera JPEG about 0.3–0.5 and
    /// PNG screenshots about 0.3–0.6; 0.45 sits at the high end of the common formats. RAW files run
    /// 1–2 bytes per pixel and are underestimated.
    static let photoBytesPerPixel = 0.45
    /// The smallest a photo file is taken to be.
    static let minimumPhotoBytes: Int64 = 100_000
    /// A Live Photo's movie: about 3 seconds of HEVC at up to 1440p, typically 2–4 MB.
    static let livePhotoMovieBytes: Int64 = 4_000_000
    /// A video's typical bitrate for its resolution, in bits per second. iPhone 4K HEVC records at
    /// about 23–53 Mbit/s and H.264 at about 45–90; 1080p H.264 at about 17; 720p at about 8.
    static func videoBitsPerSecond(pixels: Int) -> Double {
        switch pixels {
        case 6_000_000...: 50_000_000   // 4K and above (3840 × 2160 is 8.3 MP)
        case 1_500_000...: 17_000_000   // 1080p (2.1 MP)
        case 700_000...: 8_000_000      // 720p (0.9 MP)
        default: 3_000_000              // SD
        }
    }
    /// The smallest a video file is taken to be: headers and a moment of footage.
    static let minimumVideoBytes: Int64 = 500_000
    /// Audio items: 256 kbit/s AAC.
    static let audioBitsPerSecond = 256_000.0
    /// Items of an unknown type.
    static let unknownItemBytes: Int64 = 3_000_000

    static func estimatedBytes(
        mediaType: PHAssetMediaType,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        isLivePhoto: Bool,
        hasAdjustments: Bool
    ) -> Int64 {
        let pixels = max(0, pixelWidth) * max(0, pixelHeight)
        let copies: Int64 = hasAdjustments ? 2 : 1
        switch mediaType {
        case .image:
            let photo = max(minimumPhotoBytes, Int64(Double(pixels) * photoBytesPerPixel))
            let movie = isLivePhoto ? livePhotoMovieBytes : 0
            return (photo + movie) * copies
        case .video:
            let seconds = max(0, duration.isFinite ? duration : 0)
            let bits = videoBitsPerSecond(pixels: pixels) * seconds
            return max(minimumVideoBytes, Int64(bits / 8)) * copies
        case .audio:
            let seconds = max(0, duration.isFinite ? duration : 0)
            return max(minimumPhotoBytes, Int64(audioBitsPerSecond * seconds / 8))
        default:
            return unknownItemBytes
        }
    }

    static func estimatedBytes(for asset: PHAsset) -> Int64 {
        estimatedBytes(
            mediaType: asset.mediaType,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            hasAdjustments: asset.hasAdjustments
        )
    }

    /// An estimate for every item of the library. Walks the whole library, so call it off the main actor.
    static func libraryTable() -> AssetSizeTable {
        let assets = PhotoLibrary.allAssets()
        var table = AssetSizeTable(kind: .heuristic)
        table.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            table.set(estimatedBytes(for: asset), for: asset.localIdentifier)
        }
        table.libraryCount = assets.count
        table.scannedThrough = assets.count
        table.isComplete = true
        return table
    }
}
