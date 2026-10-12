import Foundation

/// A fresh folder under the system temporary directory, removed when the closure returns.
/// Tests never touch the user's real destinations or Photo Export's own preferences.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "photo-export-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

/// Writes `text` to `relativePath` inside `folder`, creating intermediate folders.
@discardableResult
func writeFile(_ text: String, to relativePath: String, in folder: URL) throws -> URL {
    let url = folder.appending(path: relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}

/// The async version, for tests whose closure awaits.
func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "photo-export-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}
