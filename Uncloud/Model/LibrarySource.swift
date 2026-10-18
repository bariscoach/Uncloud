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
        case .photosLibrary: "Photos on This Mac"
        }
    }

    /// How copying photos reads in plain language. Both sources say "exported" (never "downloaded").
    var copiedVerb: String { "exported" }
}
