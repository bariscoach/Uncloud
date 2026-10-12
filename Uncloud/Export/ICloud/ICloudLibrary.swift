import Foundation

/// Cached iCloud library facts and browsing thumbnails, and the album list that icloudpd reports.
enum ICloudLibrary {
    private static let libraryCountKey = "icloudLibraryCount"

    /// icloudpd's built-in smart albums (`PhotoLibrary.SMART_FOLDERS` in pyicloud_ipd), which `--list-albums` includes.
    static let smartAlbumNames: Set<String> = [
        "Time-lapse", "Videos", "Slo-mo", "Bursts", "Favorites",
        "Panoramas", "Screenshots", "Live", "Recently Deleted", "Hidden",
    ]

    /// The item count the browsing bridge last reported.
    static var cachedLibraryCount: Int? {
        UserDefaults.standard.object(forKey: libraryCountKey) as? Int
    }

    /// Records the library's size, as learned by the browsing bridge.
    static func cacheLibraryCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: libraryCountKey)
    }

    /// Where the library browser keeps thumbnails, keyed by iCloud asset ID.
    static var browserThumbnailDirectory: URL {
        cacheDirectory(named: "icloud-browser")
    }

    /// Forgets the cached count, thumbnails and item sizes, for sign-out. Also removes folders that earlier
    /// versions wrote (dry-run output and the recent-thumbnails downloads), since they hold iCloud data too.
    static func clearCaches() {
        UserDefaults.standard.removeObject(forKey: libraryCountKey)
        AssetSizeStore().removeAll()
        for name in ["icloud-browser", "icloud-thumbnails", "icloud-dry-run"] {
            try? FileManager.default.removeItem(at: cacheRoot.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// The user's album names, without icloudpd's smart albums.
    static func albums(appleID: String) async throws -> [String] {
        let arguments = ICloudHelperProcess.commonArguments(appleID: appleID) + ["--list-albums"]
        let (_, events) = ICloudHelperProcess.nonInteractive(arguments: arguments, appleID: appleID)
        var names: [String] = []
        for try await event in events {
            if case .albumList(let list) = event {
                names = list.filter { !smartAlbumNames.contains($0) }
            }
        }
        try Task.checkCancellation()
        return names
    }

    /// The app's folder in the user's Caches directory.
    private static var cacheRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "Uncloud", directoryHint: .isDirectory)
    }

    private static func cacheDirectory(named name: String) -> URL {
        let directory = cacheRoot.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
