import Darwin
import Foundation
import Testing
@testable import Uncloud

/// The listing `FileManager` gives for `folder`, built independently of the lister. Hidden entries are included.
private func foundationListing(_ folder: URL) throws -> [BulkDirectoryLister.Entry] {
    let keys: Set<URLResourceKey> = [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]
    let children = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: Array(keys), options: []
    )
    return try children.map { child in
        let values = try child.resourceValues(forKeys: keys)
        let kind: BulkDirectoryLister.Kind
        if values.isSymbolicLink == true {
            kind = .symlink
        } else if values.isDirectory == true {
            kind = .directory
        } else if values.isRegularFile == true {
            kind = .file
        } else {
            kind = .other
        }
        return BulkDirectoryLister.Entry(
            name: child.lastPathComponent,
            kind: kind,
            size: kind == .file ? Int64(values.fileSize ?? 0) : 0,
            modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }
}

/// Byte order, so that names compare exactly (Swift `String` equality ignores normalization).
private func byName(_ lhs: BulkDirectoryLister.Entry, _ rhs: BulkDirectoryLister.Entry) -> Bool {
    lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
}

/// Asserts that two listings hold the same entries: names byte for byte, kinds, sizes, and modification times exactly
/// (bit for bit). Order doesn't matter.
///
/// AppleDouble `._` files are left out of both sides. Foundation's listing omits them on this volume, while
/// getattrlistbulk returns them. Tests that need them check the lister directly.
private func expectSameListing(
    _ actual: [BulkDirectoryLister.Entry],
    _ expected: [BulkDirectoryLister.Entry]
) {
    let sortedActual = actual.filter { !$0.name.hasPrefix("._") }.sorted(by: byName)
    let sortedExpected = expected.filter { !$0.name.hasPrefix("._") }.sorted(by: byName)
    #expect(sortedActual.count == sortedExpected.count, "entry count")
    for (lhs, rhs) in zip(sortedActual, sortedExpected) {
        #expect(Array(lhs.name.utf8) == Array(rhs.name.utf8), "name \(rhs.name)")
        #expect(lhs.kind == rhs.kind, "kind of \(rhs.name)")
        #expect(lhs.size == rhs.size, "size of \(rhs.name)")
        #expect(lhs.modified == rhs.modified, "modified time of \(rhs.name)")
    }
}

private func writeEmpty(_ relativePath: String, in folder: URL) throws {
    try writeFile("", to: relativePath, in: folder)
}

/// A folder with the awkward cases in one place: hidden files, AppleDouble `._` entries, partial downloads, NFD and
/// emoji names, control characters, empty and 3 MB files, symlinks to a file and to a folder, and an empty folder.
private func makeMixedFolder(in folder: URL) throws {
    try writeFile("2024 photo", to: "2024/07/IMG_0001.HEIC", in: folder)
    try writeEmpty("IMG_0002.jpg", in: folder)
    try writeFile("hidden", to: ".DS_Store", in: folder)
    try writeFile("double", to: "._IMG_0001.HEIC", in: folder)
    try writeFile("partial", to: "IMG_0003.HEIC.part", in: folder)
    try writeFile("partial", to: "IMG_0004.MOV.partial", in: folder)
    try writeFile("nfd", to: "cafe\u{0301}.jpg", in: folder)
    try writeFile("emoji", to: "\u{65E5}\u{672C}\u{8A9E} \u{1F305}.jpg", in: folder)
    try writeFile("tab", to: "tab\tname.txt", in: folder)
    try writeFile("newline", to: "new\nline.txt", in: folder)
    try writeFile("escape", to: "esc\u{1B}[0m.txt", in: folder)
    try writeEmpty("zero.bin", in: folder)
    try Data(repeating: 0x5A, count: 3 * 1024 * 1024).write(to: folder.appending(path: "big.bin"))
    try FileManager.default.createSymbolicLink(
        at: folder.appending(path: "link-file.jpg"),
        withDestinationURL: folder.appending(path: "zero.bin")
    )
    try FileManager.default.createSymbolicLink(
        at: folder.appending(path: "link-folder"),
        withDestinationURL: folder.appending(path: "2024")
    )
    try FileManager.default.createDirectory(at: folder.appending(path: "empty-folder"), withIntermediateDirectories: true)
}

@Suite("BulkDirectoryLister")
struct BulkDirectoryListerTests {
    @Test func emptyFolderListsNothing() throws {
        try withTemporaryDirectory { folder in
            let entries = try BulkDirectoryLister.list(folder)
            #expect(entries.isEmpty)
        }
    }

    @Test func mixedFolderMatchesFoundationListing() throws {
        try withTemporaryDirectory { folder in
            try makeMixedFolder(in: folder)

            let bulk = try BulkDirectoryLister.list(folder)

            expectSameListing(bulk, try foundationListing(folder))
            // The lister keeps hidden entries; callers filter them.
            #expect(bulk.contains { $0.name == ".DS_Store" })
            #expect(bulk.contains { $0.name == "._IMG_0001.HEIC" })
        }
    }

    @Test func kindsSizesAndSymlinksAreReported() throws {
        try withTemporaryDirectory { folder in
            try makeMixedFolder(in: folder)

            let entries = try BulkDirectoryLister.list(folder)
            let byNameMap = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

            #expect(byNameMap["2024"]?.kind == .directory)
            #expect(byNameMap["2024"]?.size == 0)
            #expect(byNameMap["empty-folder"]?.kind == .directory)
            #expect(byNameMap["IMG_0002.jpg"]?.kind == .file)
            #expect(byNameMap["IMG_0002.jpg"]?.size == 0)
            #expect(byNameMap["big.bin"]?.size == Int64(3 * 1024 * 1024))
            #expect(byNameMap["link-file.jpg"]?.kind == .symlink)
            #expect(byNameMap["link-folder"]?.kind == .symlink, "a symlink to a folder is not a folder")
            #expect(byNameMap["link-file.jpg"]?.size == 0)
            #expect(byNameMap["IMG_0003.HEIC.part"]?.kind == .file, "the lister doesn't filter partial files")
        }
    }

    @Test func modificationTimesAreBitIdenticalToFoundation() throws {
        try withTemporaryDirectory { folder in
            var generator = SystemRandomNumberGenerator()
            for index in 0..<200 {
                let url = try writeFile("a", to: "t\(index).jpg", in: folder)
                let seconds = Int.random(in: 1_000_000_000...1_900_000_000, using: &generator)
                let nanoseconds = Int.random(in: 0..<1_000_000_000, using: &generator)
                var times = [timespec(tv_sec: seconds, tv_nsec: nanoseconds), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
                #expect(utimensat(AT_FDCWD, url.path(percentEncoded: false), &times, 0) == 0)
            }

            let bulk = try BulkDirectoryLister.list(folder)
            let foundation = try foundationListing(folder)

            expectSameListing(bulk, foundation)
            #expect(bulk.count == 200)
        }
    }

    @Test func modificationTimesMatchFoundationWithinAMicrosecond() throws {
        try withTemporaryDirectory { folder in
            let past = Date(timeIntervalSince1970: 1_234_567_890.123_456)
            try writeFile("a", to: "dated.jpg", in: folder)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: folder.appending(path: "dated.jpg").path(percentEncoded: false))

            let entries = try BulkDirectoryLister.list(folder)

            let dated = try #require(entries.first { $0.name == "dated.jpg" })
            #expect(abs(dated.modified - 1_234_567_890.123_456) < 0.000_001)
        }
    }

    @Test func moreEntriesThanOneBufferAreAllReturned() throws {
        try withTemporaryDirectory { folder in
            // Names of about 200 bytes make each record about 260 bytes, so 5,000 entries need several buffers.
            let padding = String(repeating: "x", count: 180)
            for index in 0..<5_000 {
                try writeEmpty("IMG_\(String(format: "%05d", index))_\(padding).jpg", in: folder)
            }
            #expect(5_000 * 260 > BulkDirectoryLister.bufferSize * 3, "the fixture must span several buffers")

            let bulk = try BulkDirectoryLister.list(folder)

            #expect(bulk.count == 5_000)
            #expect(Set(bulk.map(\.name)).count == 5_000, "no entry is repeated or lost at a buffer boundary")
            expectSameListing(bulk, try foundationListing(folder))
        }
    }

    @Test func unicodeNamesKeepTheirBytes() throws {
        try withTemporaryDirectory { folder in
            try writeEmpty("cafe\u{0301}.jpg", in: folder)
            try writeEmpty("\u{65E5}\u{672C}\u{8A9E} \u{1F305} \u{0646}\u{0627}\u{0645}.HEIC", in: folder)
            try writeEmpty("Ünïcode.mov", in: folder)

            let bulk = try BulkDirectoryLister.list(folder)

            #expect(bulk.count == 3)
            expectSameListing(bulk, try foundationListing(folder))
        }
    }

    @Test func controlCharacterNamesAreReturnedExactly() throws {
        try withTemporaryDirectory { folder in
            let names = ["tab\tname", "new\nline", "esc\u{1B}[0m", "bell\u{07}.jpg"]
            for name in names {
                try writeEmpty(name, in: folder)
            }

            let bulk = try BulkDirectoryLister.list(folder)

            #expect(Set(bulk.map { Array($0.name.utf8) }) == Set(names.map { Array($0.utf8) }))
        }
    }

    @Test func appleDoubleEntriesAreListedAsFiles() throws {
        try withTemporaryDirectory { folder in
            try writeFile("sidecar", to: "._IMG_0001.HEIC", in: folder)
            try writeFile("photo", to: "IMG_0001.HEIC", in: folder)

            let entries = try BulkDirectoryLister.list(folder)

            #expect(entries.contains { $0.name == "._IMG_0001.HEIC" && $0.kind == .file && $0.size == 7 })
            #expect(entries.count == 2)
        }
    }

    @Test func symlinkedFolderIsNotRecursedInto() throws {
        try withTemporaryDirectory { folder in
            try writeFile("a", to: "target/inside.jpg", in: folder)
            try FileManager.default.createSymbolicLink(
                at: folder.appending(path: "alias"),
                withDestinationURL: folder.appending(path: "target")
            )

            let entries = try BulkDirectoryLister.list(folder)

            #expect(entries.map(\.name).sorted() == ["alias", "target"])
            #expect(entries.first { $0.name == "alias" }?.kind == .symlink)
        }
    }

    @Test func unreadableFileIsStillListedWithItsSize() throws {
        try withTemporaryDirectory { folder in
            let file = try writeFile("0123456789", to: "locked.jpg", in: folder)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
            }

            let entries = try BulkDirectoryLister.list(folder)

            #expect(entries.first { $0.name == "locked.jpg" }?.size == 10)
        }
    }

    @Test func unreadableFolderThrowsPermissionDenied() throws {
        try withTemporaryDirectory { folder in
            let locked = folder.appending(path: "locked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try writeFile("a", to: "locked/IMG_0001.jpg", in: folder)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
            }

            do {
                _ = try BulkDirectoryLister.list(locked)
                Issue.record("listing an unreadable folder should throw")
            } catch let error as NSError {
                #expect(error.domain == NSPOSIXErrorDomain)
                #expect(error.code == Int(EACCES))
            }
        }
    }

    @Test func missingFolderThrowsNoSuchFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        do {
            _ = try BulkDirectoryLister.list(missing)
            Issue.record("listing a missing folder should throw")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOENT))
        }
    }

    @Test func cancelledTaskStopsBeforeListing() async throws {
        try await withTemporaryDirectoryAsync { folder in
            try writeFile("a", to: "IMG_0001.jpg", in: folder)

            let stopped = await Task { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try BulkDirectoryLister.list(folder)
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }.value

            #expect(stopped)
        }
    }

    @Test func fallbackListingAgreesWithTheBulkPass() throws {
        try withTemporaryDirectory { folder in
            try makeMixedFolder(in: folder)

            let bulk = try BulkDirectoryLister.list(folder)
            let fallback = try BulkDirectoryLister.fileManagerListing(folder)

            expectSameListing(bulk, fallback)
        }
    }
}
