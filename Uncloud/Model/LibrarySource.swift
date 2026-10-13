import Foundation

/// Where the photos come from: the iCloud Photos library, downloaded with icloudpd,
/// or the Photos library on this Mac, read with PhotoKit.
enum LibrarySource: String, CaseIterable, Identifiable, Sendable {
    case iCloud
    case photosLibrary

    var id: Self { self }

    var title: String {
        switch self {
        case .iCloud: "iCloud Photos"
        case .photosLibrary: "Photos Library on This Mac"
        }
    }

    /// How copying items reads in plain language: iCloud items are "downloaded", Photos library items "exported".
    var copiedVerb: String {
        switch self {
        case .iCloud: "downloaded"
        case .photosLibrary: "exported"
        }
    }
}
