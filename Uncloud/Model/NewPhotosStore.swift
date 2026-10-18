import Foundation

/// Saves watermarks in Application Support, one JSON file per context, so they can be read while the drive is
/// disconnected. The Photos library's identifiers, which can be many, go in a second file of their own.
struct NewPhotosStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Uncloud/NewPhotos`, in the app's sandbox container.
    static func standard() -> NewPhotosStore {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return NewPhotosStore(directory: support.appending(path: "Uncloud", directoryHint: .isDirectory)
            .appending(path: "NewPhotos", directoryHint: .isDirectory))
    }

    func watermark(for context: NewPhotosContext) -> NewPhotosWatermark? {
        guard let data = try? Data(contentsOf: watermarkURL(for: context)) else { return nil }
        return try? Self.decoder.decode(NewPhotosWatermark.self, from: data)
    }

    func save(_ watermark: NewPhotosWatermark, for context: NewPhotosContext) throws {
        let data = try Self.encoder.encode(watermark)
        try write(data, to: watermarkURL(for: context))
    }

    /// The Photos library's identifiers at the last export. Nil when the file is missing or unreadable.
    func libraryIDs(for context: NewPhotosContext) -> Set<String>? {
        guard let data = try? Data(contentsOf: idsURL(for: context)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(ids)
    }

    func saveLibraryIDs(_ ids: Set<String>, for context: NewPhotosContext) throws {
        let data = try JSONEncoder().encode(ids.sorted())
        try write(data, to: idsURL(for: context))
    }

    /// Removes both files for a context, such as when the user forgets a destination.
    func remove(for context: NewPhotosContext) {
        try? FileManager.default.removeItem(at: watermarkURL(for: context))
        try? FileManager.default.removeItem(at: idsURL(for: context))
    }

    private func watermarkURL(for context: NewPhotosContext) -> URL {
        directory.appending(path: context.storageKey + ".json")
    }

    private func idsURL(for context: NewPhotosContext) -> URL {
        directory.appending(path: context.storageKey + ".library-ids.json")
    }

    /// Written atomically, so a crash leaves the old file or the new one.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Dates keep their full precision (the default encoding), so a round trip returns the same value.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
