import Foundation

/// How exported files are arranged in the destination folder.
enum FolderLayout: String, CaseIterable, Identifiable, Sendable {
    case month
    case place
    case placeThenMonth
    case album
    case flat

    var id: Self { self }

    var title: String {
        switch self {
        case .month: "By Month"
        case .place: "By Place"
        case .placeThenMonth: "By Place, Then Month"
        case .album: "By Album"
        case .flat: "All in One Folder"
        }
    }

    var example: String {
        switch self {
        case .month: "2024/07/IMG_0001.HEIC"
        case .place: "Italy/Rome/IMG_0001.HEIC"
        case .placeThenMonth: "Italy/Rome/2024-07/IMG_0001.HEIC"
        case .album: "Trips/Rome 2024/IMG_0001.HEIC"
        case .flat: "IMG_0001.HEIC"
        }
    }

    /// The caption shown under the picker when this layout is selected, for the given source.
    /// Only `flat` has source-specific wording: icloudpd adds the file size to a clashing name, while
    /// PhotoKit exports add a number (see `ExportEngine.availableURL`).
    func caption(for source: LibrarySource) -> String? {
        guard self == .flat else { return nil }
        switch source {
        case .iCloud:
            return "Everything goes straight into your backup folder, with no subfolders. "
                + "When two files share a name, the second gets its size added, like IMG_0001-2483921.HEIC."
        case .photosLibrary:
            return "Everything goes straight into your backup folder, with no subfolders. "
                + "When two files share a name, the second gets a number, like IMG_0001 (1).HEIC."
        }
    }

    /// icloudpd's `--folder-structure` value for the whole-library run. `none` puts files directly in the folder.
    var icloudpdFolderStructure: String {
        self == .flat ? "none" : "{:%Y/%m}"
    }

    var usesPlaces: Bool {
        self == .place || self == .placeThenMonth
    }

    var usesAlbums: Bool {
        self == .album
    }

    /// iCloud downloads support folders by month, by album, or all in one folder. In one folder only the files
    /// the engine reports are recorded, never the user's own files next to them (plan 7c).
    func isAvailable(for source: LibrarySource) -> Bool {
        switch source {
        case .photosLibrary: true
        case .iCloud: self == .month || self == .album || self == .flat
        }
    }
}
