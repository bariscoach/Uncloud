import Foundation

/// The folder the library is exported into.
struct Destination: Equatable, Sendable {
    let url: URL
    let displayName: String
    let path: String
    let isOnExternalVolume: Bool

    init(url: URL) {
        self.url = url
        path = url.path(percentEncoded: false)
        displayName = FileManager.default.displayName(atPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey])
        isOnExternalVolume = values?.volumeIsInternal == false
    }

    /// Checks writability by creating and removing a probe file, which also
    /// reflects sandbox access, read-only volumes and ejected drives.
    func isWritable() -> Bool {
        let probe = url.appending(path: ".photo-export-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}
