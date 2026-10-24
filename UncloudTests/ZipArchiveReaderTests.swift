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
        let archive = Self.storedArchive(name: "big/payload.bin", payload: payload)

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

    // MARK: - In-memory archive builder for multi-chunk tests

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Bitwise CRC-32, deliberately a different implementation from the reader's table.
    private static func bitwiseCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    /// A zip with one stored entry, written in memory. Its payload is too big for a fixture.
    private static func storedArchive(name: String, payload: Data) -> Data {
        let nameBytes = Data(name.utf8)
        let crc = bitwiseCRC32(payload)
        let size = UInt32(payload.count)

        var archive = Data()
        archive.append(littleEndian(UInt32(0x0403_4b50)))
        archive.append(littleEndian(UInt16(20)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(littleEndian(crc))
        archive.append(littleEndian(size))
        archive.append(littleEndian(size))
        archive.append(littleEndian(UInt16(nameBytes.count)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(nameBytes)
        archive.append(payload)

        let directoryOffset = UInt32(archive.count)
        var directory = Data()
        directory.append(littleEndian(UInt32(0x0201_4b50)))
        directory.append(littleEndian(UInt16(20)))
        directory.append(littleEndian(UInt16(20)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(crc))
        directory.append(littleEndian(size))
        directory.append(littleEndian(size))
        directory.append(littleEndian(UInt16(nameBytes.count)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt16(0)))
        directory.append(littleEndian(UInt32(0)))
        directory.append(littleEndian(UInt32(0)))
        directory.append(nameBytes)
        archive.append(directory)

        archive.append(littleEndian(UInt32(0x0605_4b50)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(littleEndian(UInt16(0)))
        archive.append(littleEndian(UInt16(1)))
        archive.append(littleEndian(UInt16(1)))
        archive.append(littleEndian(UInt32(directory.count)))
        archive.append(littleEndian(directoryOffset))
        archive.append(littleEndian(UInt16(0)))
        return archive
    }
}
