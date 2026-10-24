import Foundation

/// One photo or video in a Takeout input, with the metadata of its JSON sidecar when it has one.
struct TakeoutItem: Sendable {
    enum Origin: Sendable {
        case file(URL)
        case zip(archive: URL, entry: ZipEntry)
    }

    let origin: Origin
    /// The file name, such as `IMG_0001.HEIC`.
    let name: String
    /// The folder's name inside Takeout, such as `Photos from 2019` or `Rome 2024`. Empty at the top.
    let folder: String
    /// The file's size: its size on disk, or the uncompressed size of a zip entry.
    let size: UInt64
    /// The modification date of the file, or of the zip archive for an entry. A last resort for the date.
    let modified: Date?
    let metadata: TakeoutMetadata?
    /// The album's name when the folder is an album, else nil.
    var album: String?
    /// `<input file name>|<path inside the input>|<size>`: identifies the file across runs, for the import journal.
    let sourceKey: String
}

/// Reads the chosen Takeout inputs into a flat list of media items. An input can be the `Takeout` folder, the
/// `Google Photos` folder, one album folder, a folder that holds zip files, or a zip file. Zip files found in a
/// folder are inputs too. Sidecars are collected across all inputs first, so a sidecar in another zip part still
/// finds its photo. Reads only names, sidecars and zip directories: media bytes are never loaded here.
enum TakeoutSource {
    struct Result: Sendable {
        var items: [TakeoutItem]
        /// Names of the inputs that couldn't be read (missing, or not a zip archive).
        var unreadable: [String]
    }

    /// Sidecars larger than this are ignored: Takeout's JSON files are a few kilobytes.
    static let maxSidecarSize = 1 << 20
    private static let googlePhotosFolder = "Google Photos"
    private static let albumMetadataName = "metadata.json"

    static func scan(_ inputs: [URL]) throws -> Result {
        let scan = Scan()
        for input in inputs {
            try Task.checkCancellation()
            let name = input.lastPathComponent
            if input.pathExtension.lowercased() == "zip" {
                scan.addArchive(input)
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path(percentEncoded: false), isDirectory: &isDirectory) else {
                scan.unreadable.append(name)
                continue
            }
            if isDirectory.boolValue {
                try scan.addFolder(input)
            } else if ICloudDownloadPaths.hasDownloadExtension(name) {
                scan.addFile(input, folder: "")
            } else {
                scan.unreadable.append(name)
            }
        }

        var items: [TakeoutItem] = []
        items.reserveCapacity(scan.media.count)
        let byFolder = Dictionary(grouping: scan.media, by: \.folder)
        for folder in byFolder.keys.sorted() {
            try Task.checkCancellation()
            items += try takeoutItems(in: folder, media: byFolder[folder] ?? [], sidecars: scan.sidecars[folder] ?? [:], scan: scan)
        }
        items.sort { $0.sourceKey < $1.sourceKey }
        return Result(items: items, unreadable: scan.unreadable)
    }

    /// The album name for a folder. A folder is an album when Takeout wrote an album `metadata.json` in it, unless its
    /// name is `Photos from YYYY`, which Takeout uses for the photos of a year.
    static func albumName(folder: String, hasAlbumMetadata: Bool) -> String? {
        guard hasAlbumMetadata, let last = folder.split(separator: "/").last else { return nil }
        return isPhotosFromYear(String(last)) ? nil : String(last)
    }

    /// `Photos from 2019`: the name Takeout gives a year's photos.
    static func isPhotosFromYear(_ name: String) -> Bool {
        let prefix = "Photos from "
        guard name.hasPrefix(prefix) else { return false }
        let year = name.dropFirst(prefix.count)
        return year.count == 4 && year.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A file's folder inside Takeout, from its path components (the input's name first, then the folders). Everything
    /// up to and including `Google Photos` is dropped, so a folder reads the same whichever folder was chosen: the
    /// `Takeout` folder, the `Google Photos` folder, an album, or a zip's entries.
    static func folderKey(for components: [String]) -> String {
        var parts = components
        if let index = parts.firstIndex(of: googlePhotosFolder) {
            parts = Array(parts[(index + 1)...])
        }
        return parts.joined(separator: "/")
    }

    /// A line-safe piece of a source key: control characters, tabs included, become spaces.
    static func keyText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    // MARK: - Items

    /// The items of one folder: each media file with its sidecar's metadata. Sidecars are matched by name, then by
    /// title for the files that no name matched. Each folder's parsed sidecars are dropped when the folder is done.
    private static func takeoutItems(
        in folder: String,
        media: [Found],
        sidecars: [String: Found],
        scan: Scan
    ) throws -> [TakeoutItem] {
        let sidecarNames = Set(sidecars.keys)
        let mediaNames = Set(media.map(\.name))
        let index = TakeoutSidecarMatcher.Index(jsonNames: sidecarNames, mediaNames: mediaNames)
        let album = albumName(folder: folder, hasAlbumMetadata: sidecarNames.contains(albumMetadataName))
        let displayFolder = folder.split(separator: "/").last.map(String.init) ?? ""

        var parsed: [String: Parsed] = [:]
        func metadata(_ name: String) -> TakeoutMetadata? {
            if let cached = parsed[name] { return cached.metadata }
            let value = sidecars[name].flatMap { read($0, scan: scan) }.flatMap(TakeoutMetadata.parse)
            parsed[name] = Parsed(metadata: value)
            return value
        }
        var titleIndex: [String: String]?

        var result: [TakeoutItem] = []
        result.reserveCapacity(media.count)
        for file in media.sorted(by: { $0.name < $1.name }) {
            var sidecarName = TakeoutSidecarMatcher.sidecar(for: file.name, in: index)
            if sidecarName == nil {
                if titleIndex == nil {
                    var index: [String: String] = [:]
                    for name in sidecarNames.sorted() where name != albumMetadataName {
                        if let title = metadata(name)?.title, index[title] == nil {
                            index[title] = name
                        }
                    }
                    titleIndex = index
                }
                sidecarName = titleIndex?[file.name]
            }
            result.append(TakeoutItem(
                origin: file.origin,
                name: file.name,
                folder: displayFolder,
                size: file.size,
                modified: file.modified,
                metadata: sidecarName.flatMap(metadata),
                album: album,
                sourceKey: file.sourceKey
            ))
        }
        return result
    }

    private struct Parsed {
        let metadata: TakeoutMetadata?
    }

    /// A sidecar's bytes, or nil when it is too big or can't be read. Takeout's sidecars are a few kilobytes.
    private static func read(_ found: Found, scan: Scan) -> Data? {
        guard found.size <= UInt64(maxSidecarSize) else { return nil }
        switch found.origin {
        case .file(let url):
            return try? Data(contentsOf: url)
        case .zip(let archive, let entry):
            return try? scan.readers[archive]?.data(for: entry, limit: maxSidecarSize)
        }
    }

    // MARK: - Scanning

    /// A file found in an input, before its sidecar is matched.
    fileprivate struct Found {
        let origin: TakeoutItem.Origin
        let name: String
        /// The folder key (see `folderKey(for:)`).
        let folder: String
        let size: UInt64
        let modified: Date?
        let sourceKey: String
    }

    /// Everything the inputs contain, gathered in one pass. Zip readers are kept so sidecars can be read from them.
    fileprivate final class Scan {
        var media: [Found] = []
        /// Sidecars by folder key, then by file name.
        var sidecars: [String: [String: Found]] = [:]
        var readers: [URL: ZipArchiveReader] = [:]
        var unreadable: [String] = []

        func addFile(_ url: URL, folder: String) {
            let name = url.lastPathComponent
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            add(Found(
                origin: .file(url), name: name, folder: folder, size: size, modified: modified,
                sourceKey: "\(TakeoutSource.keyText(name))|\(TakeoutSource.keyText(name))|\(size)"
            ))
        }

        /// Walks a folder. Zip files in it become archive inputs. Hidden files and packages are skipped.
        func addFolder(_ root: URL) throws {
            let rootName = root.lastPathComponent
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let walker = FileManager.default.enumerator(
                at: root.standardizedFileURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                unreadable.append(rootName)
                return
            }
            let rootDepth = root.standardizedFileURL.pathComponents.count
            for case let url as URL in walker {
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(rootDepth))
                guard !parts.isEmpty, !parts.contains(where: { $0 == "__MACOSX" }) else { continue }
                if url.pathExtension.lowercased() == "zip" {
                    addArchive(url)
                    continue
                }
                let folder = TakeoutSource.folderKey(for: [rootName] + parts.dropLast())
                let size = UInt64(values?.fileSize ?? 0)
                let path = parts.joined(separator: "/")
                add(Found(
                    origin: .file(url),
                    name: url.lastPathComponent,
                    folder: folder,
                    size: size,
                    modified: values?.contentModificationDate,
                    sourceKey: "\(TakeoutSource.keyText(rootName))|\(TakeoutSource.keyText(path))|\(size)"
                ))
            }
        }

        /// Opens a zip and records each of its files. A zip that can't be opened is reported as unreadable.
        func addArchive(_ url: URL) {
            let archiveName = url.lastPathComponent
            do {
                let reader = try ZipArchiveReader(url: url)
                readers[url] = reader
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                for entry in reader.entries where !entry.isDirectory {
                    let parts = entry.path.split(separator: "/").map(String.init)
                    guard let name = parts.last, !parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) else {
                        continue
                    }
                    let size = entry.uncompressedSize
                    add(Found(
                        origin: .zip(archive: url, entry: entry),
                        name: name,
                        folder: TakeoutSource.folderKey(for: Array(parts.dropLast())),
                        size: size,
                        modified: modified,
                        sourceKey: "\(TakeoutSource.keyText(archiveName))|\(TakeoutSource.keyText(entry.path))|\(size)"
                    ))
                }
            } catch {
                unreadable.append(archiveName)
            }
        }

        /// Sorts a found file into media or sidecars. Only Takeout's `.json` files are sidecars. `.xmp` files are
        /// not media: Takeout doesn't write them, and importing one would create a second item.
        private func add(_ found: Found) {
            let lower = found.name.lowercased()
            if lower.hasSuffix(".json") {
                sidecars[found.folder, default: [:]][found.name] = found
            } else if ICloudDownloadPaths.hasDownloadExtension(found.name), !lower.hasSuffix(".xmp") {
                media.append(found)
            }
        }
    }
}
