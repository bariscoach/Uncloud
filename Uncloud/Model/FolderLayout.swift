import Foundation

/// How exported files are arranged in the destination folder.
enum FolderLayout: String, CaseIterable, Identifiable, Sendable {
    case month
    case place
    case placeThenMonth
    case album

    var id: Self { self }

    var title: String {
        switch self {
        case .month: "By Month"
        case .place: "By Place"
        case .placeThenMonth: "By Place, Then Month"
        case .album: "By Album"
        }
    }

    var example: String {
        switch self {
        case .month: "2024/07/IMG_0001.HEIC"
        case .place: "Italy/Rome/IMG_0001.HEIC"
        case .placeThenMonth: "Italy/Rome/2024-07/IMG_0001.HEIC"
        case .album: "Trips/Rome 2024/IMG_0001.HEIC"
        }
    }

    var usesPlaces: Bool {
        self == .place || self == .placeThenMonth
    }

    var usesAlbums: Bool {
        self == .album
    }

    /// iCloud downloads only support folders by month or by album.
    func isAvailable(for source: LibrarySource) -> Bool {
        switch source {
        case .photosLibrary: true
        case .iCloud: self == .month || self == .album
        }
    }
}
