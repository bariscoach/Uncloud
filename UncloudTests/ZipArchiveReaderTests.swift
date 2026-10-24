import CryptoKit
import Foundation
import Testing
@testable import Uncloud

@Suite("Zip archive reader")
struct ZipArchiveReaderTests {
    /// Decodes one of `ZipFixtures`' base64 archives.
    private static func archive(_ base64: String) -> Data {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            fatalError("zip fixture is not valid base64")
        }
        return data
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The case name of a `ZipError`, so a test can assert which error was thrown.
    private static func caseName(_ error: ZipError?) -> String? {
        switch error {
        case .notAZip: "notAZip"
        case .unsupported: "unsupported"
        case .corrupt: "corrupt"
        case .unsafePath: "unsafePath"
        case .tooLarge: "tooLarge"
        case nil: nil
        }
    }

    /// Writes the archive into `folder` and opens it.
    private func open(_ data: Data, in folder: URL) throws -> ZipArchiveReader {
        let url = folder.appending(path: "archive.zip")
        try data.write(to: url)
        return try ZipArchiveReader(url: url)
    }

    /// Extracts one entry to a file in `folder` and reads the file back.
    private func extracted(_ reader: ZipArchiveReader, _ entry: ZipEntry, in folder: URL) throws -> Data {
        let url = folder.appending(path: "extracted-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try reader.extract(entry, to: handle) { _ in }
        }
        return try Data(contentsOf: url)
    }

    private func entry(_ reader: ZipArchiveReader, named path: String) throws -> ZipEntry {
        try #require(reader.entries.first { $0.path == path })
    }

    @Test func storedEntryExtractsExactBytes() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.stored), in: folder)
            let hello = try entry(reader, named: "notes/hello.txt")

            #expect(reader.entries.count == 1)
            #expect(hello.method == 0)
            #expect(hello.uncompressedSize == UInt64(ZipFixtures.storedText.utf8.count))
            #expect(hello.compressedSize == hello.uncompressedSize)
            #expect(hello.isDirectory == false)
            #expect(hello.isEncrypted == false)
            #expect(try extracted(reader, hello, in: folder) == Data(ZipFixtures.storedText.utf8))
        }
    }

    @Test func deflatedEntriesMatchTheirDigests() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.deflated), in: folder)
            let notes = try entry(reader, named: "photos/notes.txt")
            let random = try entry(reader, named: "photos/random.bin")

            #expect(notes.method == 8)
            #expect(random.method == 8)
            #expect(notes.uncompressedSize == UInt64(ZipFixtures.deflatedNotesSize))
            #expect(random.uncompressedSize == 2048)
            #expect(random.compressedSize < random.uncompressedSize + 64)

            let notesBytes = try extracted(reader, notes, in: folder)
            let randomBytes = try extracted(reader, random, in: folder)
            #expect(Self.sha256Hex(notesBytes) == ZipFixtures.deflatedNotesSHA256)
            #expect(Self.sha256Hex(randomBytes) == ZipFixtures.deflatedRandomSHA256)
        }
    }

    @Test func utf8NameDecodesAsUnicode() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.utf8Name), in: folder)

            #expect(reader.entries.map(\.path) == ["Caf\u{00E9}.jpg"])
            let photo = try entry(reader, named: "Caf\u{00E9}.jpg")
            #expect(try extracted(reader, photo, in: folder) == Data(ZipFixtures.utf8Contents.utf8))
        }
    }

    @Test func directoryEntryIsListedWithoutBytes() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.directory), in: folder)
            let directory = try entry(reader, named: "Takeout/Google Photos/")
            let photo = try entry(reader, named: "Takeout/Google Photos/IMG_0001.jpg")

            #expect(directory.isDirectory)
            #expect(directory.uncompressedSize == 0)
            #expect(try extracted(reader, directory, in: folder).isEmpty)
            #expect(photo.isDirectory == false)
            #expect(try extracted(reader, photo, in: folder) == Data(ZipFixtures.directoryPhotoContents.utf8))
        }
    }

    @Test func zip64ArchiveReadsSizesAndOffsets() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.zip64), in: folder)
            let big = try entry(reader, named: "big/zip64.txt")

            #expect(reader.entries.count == 1)
            #expect(big.uncompressedSize == UInt64(ZipFixtures.zip64Size))
            #expect(big.localHeaderOffset == 0)
            #expect(Self.sha256Hex(try extracted(reader, big, in: folder)) == ZipFixtures.zip64SHA256)
        }
    }

    @Test func corruptCRCIsReportedWhenExtracting() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.corruptCRC), in: folder)
            let hello = try entry(reader, named: "notes/hello.txt")

            let error = #expect(throws: ZipError.self) {
                _ = try reader.data(for: hello, limit: 1 << 20)
            }
            #expect(Self.caseName(error) == "corrupt")
        }
    }

    @Test func bzip2EntryIsListedButCannotBeExtracted() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.bzip2), in: folder)
            let bzip = try entry(reader, named: "photos/bzip.txt")

            #expect(bzip.method == 12)
            let error = #expect(throws: ZipError.self) {
                _ = try reader.data(for: bzip, limit: 1 << 20)
            }
            #expect(Self.caseName(error) == "unsupported")
        }
    }

    @Test func fileThatIsNotAZipIsRefused() {
        withTemporaryDirectory { folder in
            let text = Data("This is plain text, not a zip archive, and it is long enough to be scanned.".utf8)
            let error = #expect(throws: ZipError.self) {
                _ = try open(text, in: folder)
            }
            #expect(Self.caseName(error) == "notAZip")
        }
    }

    @Test func pathThatClimbsOutIsRefusedWhenOpening() {
        withTemporaryDirectory { folder in
            let error = #expect(throws: ZipError.self) {
                _ = try open(Self.archive(ZipFixtures.unsafePath), in: folder)
            }
            #expect(Self.caseName(error) == "unsafePath")
        }
    }

    @Test func dataForSmallEntryRespectsTheLimit() throws {
        try withTemporaryDirectory { folder in
            let reader = try open(Self.archive(ZipFixtures.stored), in: folder)
            let hello = try entry(reader, named: "notes/hello.txt")

            #expect(try reader.data(for: hello, limit: 1 << 20) == Data(ZipFixtures.storedText.utf8))
            let error = #expect(throws: ZipError.self) {
                _ = try reader.data(for: hello, limit: 4)
            }
            #expect(Self.caseName(error) == "tooLarge")
        }
    }

    @Test func largeStoredEntryStreamsInChunksOfAtMostOneMebibyte() throws {
        let payload = Data((0..<(2 * 1024 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 9)) })
        let archive = ZipTestArchive.stored(path: "big/payload.bin", payload: payload)

        try withTemporaryDirectory { folder in
            let reader = try open(archive, in: folder)
            let big = try entry(reader, named: "big/payload.bin")
            let url = folder.appending(path: "payload.out")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            var sizes: [Int] = []
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try reader.extract(big, to: handle) { sizes.append($0.count) }
            }

            #expect(sizes == [1 << 20, 1 << 20, 123])
            #expect(try Data(contentsOf: url) == payload)
        }
    }

    @Test func multiChunkDeflatedEntryRoundTripsAndChecksCRC() throws {
        // Three MiB that compress well, so the entry inflates in several output chunks of at most one MiB.
        let payload = Data((0..<(3 * 1024 * 1024 + 4567)).map { index in
            UInt8(truncatingIfNeeded: (index % 4093) ^ (index / 4093))
        })
        let archive = ZipTestArchive.archive([
            ZipTestArchive.member(path: "big/deflated.bin", payload: payload, deflated: true),
        ])

        try withTemporaryDirectory { folder in
            let reader = try open(archive, in: folder)
            let big = try entry(reader, named: "big/deflated.bin")
            #expect(big.method == 8)
            #expect(big.uncompressedSize == UInt64(payload.count))
            #expect(big.compressedSize < big.uncompressedSize)

            let url = folder.appending(path: "deflated.out")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            var sizes: [Int] = []
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try reader.extract(big, to: handle) { sizes.append($0.count) }
            }

            #expect(sizes.count >= 3)
            #expect(sizes.allSatisfy { $0 <= 1 << 20 })
            #expect(sizes.reduce(0, +) == payload.count)
            #expect(try Data(contentsOf: url) == payload)
        }
    }

    @Test func deflatedEntryWithWrongCRCIsCorrupt() throws {
        let payload = Data(repeating: 0x41, count: 5000)
        let archive = ZipTestArchive.archive([
            ZipTestArchive.member(path: "bad.bin", payload: payload, deflated: true, crcOverride: 0xDEAD_BEEF),
        ])

        try withTemporaryDirectory { folder in
            let reader = try open(archive, in: folder)
            let bad = try entry(reader, named: "bad.bin")
            let error = #expect(throws: ZipError.self) {
                _ = try reader.data(for: bad, limit: 1 << 20)
            }
            #expect(Self.caseName(error) == "corrupt")
        }
    }
}
