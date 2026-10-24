import Compression
import Foundation

/// One record from a zip's central directory.
struct ZipEntry: Sendable, Hashable {
    /// Path inside the archive, with "/" separators. Directories end with "/".
    let path: String
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc32: UInt32
    /// 0 (stored) or 8 (deflate). Other methods are listed, but extracting them throws `ZipError.unsupported`.
    let method: UInt16
    let localHeaderOffset: UInt64
    let isDirectory: Bool
    let isEncrypted: Bool
}

enum ZipError: LocalizedError {
    /// The file has no end-of-central-directory record.
    case notAZip
    /// The entry uses a feature this reader doesn't implement: another compression method, encryption, or several disks.
    case unsupported(String)
    /// The archive or entry data is damaged: bad signatures, truncated data, or a size or CRC mismatch.
    case corrupt(String)
    /// An entry path is absolute or has a ".." component, so it could write outside the destination.
    case unsafePath(String)
    /// An entry is bigger than the caller's limit.
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .notAZip:
            "The file isn’t a zip archive."
        case .unsupported(let path):
            "“\(path)” uses a zip feature Uncloud can’t read."
        case .corrupt(let detail):
            "The zip archive is damaged: \(detail)."
        case .unsafePath(let path):
            "The zip archive has an unsafe path: “\(path)”."
        case .tooLarge(let path):
            "“\(path)” is too large to read into memory."
        }
    }
}

/// Reads a zip archive in place, without unpacking it first and without a subprocess, so it works in the sandbox.
/// Stored and deflated entries are supported, including ZIP64 and UTF-8 names.
final class ZipArchiveReader: Sendable {
    /// Chunk size for file reads and for decompressed output.
    private static let chunkSize = 1 << 20
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let zip64EndSignature: UInt32 = 0x0606_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64ExtraID: UInt16 = 0x0001
    private static let endRecordSize = 22
    private static let centralHeaderSize = 46
    private static let localHeaderSize = 30

    private let url: URL
    let entries: [ZipEntry]

    /// Reads the central directory. Throws `notAZip` if the file has no end record, and `unsafePath` if any entry
    /// would extract outside its destination; such an archive is refused as a whole.
    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let directory = try Self.locateDirectory(in: handle, size: size)
        let bytes = try Self.read(handle, at: directory.offset, count: Int(directory.size))

        var entries: [ZipEntry] = []
        entries.reserveCapacity(directory.count)
        var cursor = 0
        for _ in 0..<directory.count {
            let (entry, next) = try Self.parseCentralHeader(bytes, at: cursor)
            try Self.checkPath(entry.path)
            entries.append(entry)
            cursor = next
        }
        self.entries = entries
    }

    /// The entry's bytes in memory, for small files such as JSON sidecars. Throws `tooLarge` if the entry is bigger than
    /// `limit`.
    func data(for entry: ZipEntry, limit: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(limit) else { throw ZipError.tooLarge(entry.path) }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        try stream(entry) { result.append($0) }
        return result
    }

    /// Writes the entry's bytes to `handle` in chunks, calling `chunk` with each piece as it's written (for example, to
    /// hash it). Throws `corrupt` on a size or CRC mismatch. By then some bytes may already be in `handle`, so callers
    /// should discard the partial file.
    func extract(_ entry: ZipEntry, to handle: FileHandle, chunk: (Data) -> Void) throws {
        try stream(entry) { data in
            try handle.write(contentsOf: data)
            chunk(data)
        }
    }

    // MARK: - Extraction

    /// Feeds the entry's decompressed bytes to `sink` one chunk at a time, verifying size and CRC at the end. Opens its
    /// own file handle, so concurrent calls on one reader are safe.
    private func stream(_ entry: ZipEntry, _ sink: (Data) throws -> Void) throws {
        guard !entry.isEncrypted, entry.method == 0 || entry.method == 8 else {
            throw ZipError.unsupported(entry.path)
        }
        if entry.isDirectory { return }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try Self.read(handle, at: entry.localHeaderOffset, count: Self.localHeaderSize)
        guard try Self.le(UInt32.self, header, 0) == Self.localHeaderSignature else {
            throw ZipError.corrupt("bad local header for \(entry.path)")
        }
        let nameLength = UInt64(try Self.le(UInt16.self, header, 26))
        let extraLength = UInt64(try Self.le(UInt16.self, header, 28))
        let dataStart = entry.localHeaderOffset + UInt64(Self.localHeaderSize) + nameLength + extraLength

        var verifier = EntryVerifier(entry: entry)
        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipError.corrupt("stored size mismatch for \(entry.path)")
            }
            try Self.copyStored(handle, start: dataStart, length: entry.compressedSize, verifier: &verifier, sink: sink)
        } else {
            try Self.inflate(handle, start: dataStart, length: entry.compressedSize, verifier: &verifier, sink: sink)
        }
        try verifier.finish()
    }

    private static func copyStored(
        _ handle: FileHandle,
        start: UInt64,
        length: UInt64,
        verifier: inout EntryVerifier,
        sink: (Data) throws -> Void
    ) throws {
        var remaining = length
        var position = start
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, UInt64(chunkSize)))
            let bytes = try read(handle, at: position, count: count)
            try verifier.accept(bytes)
            try sink(Data(bytes))
            position += UInt64(count)
            remaining -= UInt64(count)
        }
    }

    /// Raw DEFLATE (`COMPRESSION_ZLIB` is headerless in Apple's Compression framework) through `compression_stream`.
    private static func inflate(
        _ handle: FileHandle,
        start: UInt64,
        length: UInt64,
        verifier: inout EntryVerifier,
        sink: (Data) throws -> Void
    ) throws {
        // Placeholder pointers with zero sizes: the real buffers are set before each `compression_stream_process` call.
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("could not start decompression")
        }
        defer { compression_stream_destroy(&stream) }

        var output = [UInt8](repeating: 0, count: chunkSize)
        var input: [UInt8] = []
        var inputOffset = 0
        var remaining = length
        var position = start
        var finished = false

        while !finished {
            try Task.checkCancellation()
            if inputOffset == input.count && remaining > 0 {
                let count = Int(min(remaining, UInt64(chunkSize)))
                input = try read(handle, at: position, count: count)
                position += UInt64(count)
                remaining -= UInt64(count)
                inputOffset = 0
            }
            let inputDone = inputOffset == input.count && remaining == 0
            let flags: Int32 = inputDone ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            // An empty array has no base address, so give the decoder a valid one-byte buffer with zero length.
            let source = input.isEmpty ? [0] : input
            let before = inputOffset

            var status = COMPRESSION_STATUS_OK
            let produced = output.withUnsafeMutableBufferPointer { dst in
                source.withUnsafeBufferPointer { src -> Int in
                    stream.src_ptr = src.baseAddress! + inputOffset
                    stream.src_size = input.count - inputOffset
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = dst.count
                    status = compression_stream_process(&stream, flags)
                    return dst.count - stream.dst_size
                }
            }
            inputOffset = input.count - stream.src_size

            if produced > 0 {
                try verifier.accept(Array(output[0..<produced]))
                try sink(Data(output[0..<produced]))
            }
            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
            case COMPRESSION_STATUS_OK:
                if inputDone && produced == 0 {
                    throw ZipError.corrupt("compressed data ends early")
                }
                if produced == 0 && inputOffset == before && !inputDone {
                    throw ZipError.corrupt("decompression made no progress")
                }
            default:
                throw ZipError.corrupt("bad deflate data")
            }
        }
    }

    // MARK: - Central directory

    /// Finds the end record and returns where the central directory is, how big it is, and how many entries it lists.
    /// Switches to the ZIP64 end record when the classic fields are saturated.
    private static func locateDirectory(in handle: FileHandle, size: UInt64) throws -> (offset: UInt64, size: UInt64, count: Int) {
        guard size >= UInt64(endRecordSize) else { throw ZipError.notAZip }
        // The end record is at most 22 bytes plus a 65,535-byte comment from the end of the file.
        let tailLength = min(size, UInt64(endRecordSize + 65_535))
        let tailStart = size - tailLength
        let tail = try read(handle, at: tailStart, count: Int(tailLength))
        guard let end = try endRecordPosition(in: tail) else { throw ZipError.notAZip }

        let disk = try le(UInt16.self, tail, end + 4)
        let directoryDisk = try le(UInt16.self, tail, end + 6)
        let entriesOnDisk = try le(UInt16.self, tail, end + 8)
        var count = UInt64(try le(UInt16.self, tail, end + 10))
        var directorySize = UInt64(try le(UInt32.self, tail, end + 12))
        var directoryOffset = UInt64(try le(UInt32.self, tail, end + 16))

        let saturated = entriesOnDisk == 0xFFFF || count == 0xFFFF || directorySize == 0xFFFF_FFFF
            || directoryOffset == 0xFFFF_FFFF || disk == 0xFFFF
        if saturated {
            let endOffset = tailStart + UInt64(end)
            guard endOffset >= 20 else { throw ZipError.corrupt("missing ZIP64 locator") }
            let locator = try read(handle, at: endOffset - 20, count: 20)
            guard try le(UInt32.self, locator, 0) == zip64LocatorSignature else {
                throw ZipError.corrupt("missing ZIP64 locator")
            }
            let record = try read(handle, at: try le(UInt64.self, locator, 8), count: 56)
            guard try le(UInt32.self, record, 0) == zip64EndSignature else {
                throw ZipError.corrupt("missing ZIP64 end record")
            }
            guard try le(UInt32.self, record, 16) == 0, try le(UInt32.self, record, 20) == 0 else {
                throw ZipError.unsupported("multi-disk archive")
            }
            count = try le(UInt64.self, record, 32)
            directorySize = try le(UInt64.self, record, 40)
            directoryOffset = try le(UInt64.self, record, 48)
        } else if disk != 0 || directoryDisk != 0 {
            throw ZipError.unsupported("multi-disk archive")
        }

        guard directoryOffset <= size, directorySize <= size - directoryOffset,
              count * UInt64(centralHeaderSize) <= directorySize
        else {
            throw ZipError.corrupt("central directory is out of range")
        }
        return (directoryOffset, directorySize, Int(count))
    }

    /// Offset of the end record within `tail`. It must be the last record, so its comment length reaches the end of the
    /// tail exactly; that rules out a stray signature inside a comment or in entry data.
    private static func endRecordPosition(in tail: [UInt8]) throws -> Int? {
        guard tail.count >= endRecordSize else { return nil }
        var position = tail.count - endRecordSize
        while position >= 0 {
            if try le(UInt32.self, tail, position) == endSignature {
                let commentLength = Int(try le(UInt16.self, tail, position + 20))
                if position + endRecordSize + commentLength == tail.count {
                    return position
                }
            }
            position -= 1
        }
        return nil
    }

    /// Parses one central directory header at `start` and returns the entry and the offset of the next header.
    private static func parseCentralHeader(_ bytes: [UInt8], at start: Int) throws -> (ZipEntry, Int) {
        guard try le(UInt32.self, bytes, start) == centralHeaderSignature else {
            throw ZipError.corrupt("bad central directory entry")
        }
        let flags = try le(UInt16.self, bytes, start + 8)
        let method = try le(UInt16.self, bytes, start + 10)
        let crc32 = try le(UInt32.self, bytes, start + 16)
        var compressedSize = UInt64(try le(UInt32.self, bytes, start + 20))
        var uncompressedSize = UInt64(try le(UInt32.self, bytes, start + 24))
        let nameLength = Int(try le(UInt16.self, bytes, start + 28))
        let extraLength = Int(try le(UInt16.self, bytes, start + 30))
        let commentLength = Int(try le(UInt16.self, bytes, start + 32))
        var localHeaderOffset = UInt64(try le(UInt32.self, bytes, start + 42))

        let nameStart = start + centralHeaderSize
        let extraStart = nameStart + nameLength
        let next = extraStart + extraLength + commentLength
        guard next <= bytes.count else { throw ZipError.corrupt("central directory entry runs past its end") }

        let nameBytes = Array(bytes[nameStart..<extraStart])
        let path = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""

        // Saturated 32-bit fields are replaced, in this order, by the ZIP64 extra field's 64-bit values.
        let saturatedFields = [uncompressedSize, compressedSize, localHeaderOffset].filter { $0 == 0xFFFF_FFFF }.count
        if saturatedFields > 0 {
            var found = false
            var field = extraStart
            while field + 4 <= extraStart + extraLength {
                let id = try le(UInt16.self, bytes, field)
                let size = Int(try le(UInt16.self, bytes, field + 2))
                let body = field + 4
                guard body + size <= extraStart + extraLength else { throw ZipError.corrupt("bad extra field for \(path)") }
                if id == zip64ExtraID {
                    found = true
                    guard size >= saturatedFields * 8 else { throw ZipError.corrupt("short ZIP64 field for \(path)") }
                    var cursor = body
                    if uncompressedSize == 0xFFFF_FFFF {
                        uncompressedSize = try le(UInt64.self, bytes, cursor)
                        cursor += 8
                    }
                    if compressedSize == 0xFFFF_FFFF {
                        compressedSize = try le(UInt64.self, bytes, cursor)
                        cursor += 8
                    }
                    if localHeaderOffset == 0xFFFF_FFFF {
                        localHeaderOffset = try le(UInt64.self, bytes, cursor)
                    }
                }
                field = body + size
            }
            guard found else { throw ZipError.corrupt("missing ZIP64 field for \(path)") }
        }

        let entry = ZipEntry(
            path: path,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            crc32: crc32,
            method: method,
            localHeaderOffset: localHeaderOffset,
            isDirectory: path.hasSuffix("/"),
            isEncrypted: flags & 1 != 0
        )
        return (entry, next)
    }

    /// Refuses names that are absolute, use backslashes, contain NUL, or have a ".." component.
    private static func checkPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let unsafe = path.hasPrefix("/") || path.contains("\\") || path.contains("\0") || components.contains { $0 == ".." }
        if unsafe { throw ZipError.unsafePath(path) }
    }

    // MARK: - Byte helpers

    /// Reads exactly `count` bytes at `offset`, or throws `corrupt` if the file ends first.
    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZipError.corrupt("unexpected end of file") }
        return [UInt8](data)
    }

    /// The little-endian integer of type `T` at `offset`, or `corrupt` if the bytes run past the end.
    private static func le<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], _ offset: Int) throws -> T {
        let width = T.bitWidth / 8
        guard offset >= 0, offset + width <= bytes.count else { throw ZipError.corrupt("truncated header") }
        var value: T = 0
        for index in 0..<width {
            value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        return value
    }
}

/// Checks an entry's output as it's produced: never more than the header's size, and the exact size and CRC at the end.
private struct EntryVerifier {
    let entry: ZipEntry
    private var produced: UInt64 = 0
    private var crc = CRC32()

    init(entry: ZipEntry) {
        self.entry = entry
    }

    mutating func accept(_ bytes: [UInt8]) throws {
        produced += UInt64(bytes.count)
        guard produced <= entry.uncompressedSize else {
            throw ZipError.corrupt("\(entry.path) is bigger than its header says")
        }
        crc.update(bytes)
    }

    func finish() throws {
        guard produced == entry.uncompressedSize else {
            throw ZipError.corrupt("\(entry.path) has the wrong size")
        }
        guard crc.digest == entry.crc32 else {
            throw ZipError.corrupt("CRC mismatch for \(entry.path)")
        }
    }
}

/// Table-driven CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as zip uses it.
private struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var digest: UInt32 { ~state }

    mutating func update(_ bytes: [UInt8]) {
        for byte in bytes {
            state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
        }
    }
}
