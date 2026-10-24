import Compression
import Foundation

/// Writes small zip archives in memory for tests: stored or raw-DEFLATE entries, with optional wrong checksums.
/// The archives have no ZIP64 records and no timestamps, which the reader doesn't need.
enum ZipTestArchive {
    /// One entry: the bytes stored in the archive (compressed for method 8), and the header values for it.
    struct Member {
        let path: String
        let stored: Data
        let method: UInt16
        let uncompressedSize: UInt32
        let crc: UInt32
    }

    /// An entry holding `payload`. With `deflated`, the stored bytes are raw DEFLATE. `crcOverride` writes a wrong
    /// checksum, for corrupt-entry tests.
    static func member(path: String, payload: Data, deflated: Bool = false, crcOverride: UInt32? = nil) -> Member {
        Member(
            path: path,
            stored: deflated ? rawDeflate(payload) : payload,
            method: deflated ? 8 : 0,
            uncompressedSize: UInt32(payload.count),
            crc: crcOverride ?? crc32(payload)
        )
    }

    /// A zip with one stored entry.
    static func stored(path: String, payload: Data) -> Data {
        archive([member(path: path, payload: payload)])
    }

    /// The zip holding `members`, in order: local headers and data, then the central directory and its end record.
    static func archive(_ members: [Member]) -> Data {
        var body = Data()
        var directory = Data()
        for member in members {
            let offset = UInt32(body.count)
            let name = Data(member.path.utf8)
            let size = UInt32(member.stored.count)
            body.append(bytes(
                le(UInt32(0x0403_4b50)), le(UInt16(20)), le(UInt16(0)), le(member.method),
                le(UInt16(0)), le(UInt16(0)), le(member.crc),
                le(size), le(member.uncompressedSize),
                le(UInt16(name.count)), le(UInt16(0)), name, member.stored
            ))
            directory.append(bytes(
                le(UInt32(0x0201_4b50)), le(UInt16(20)), le(UInt16(20)), le(UInt16(0)),
                le(member.method), le(UInt16(0)), le(UInt16(0)), le(member.crc),
                le(size), le(member.uncompressedSize),
                le(UInt16(name.count)), le(UInt16(0)), le(UInt16(0)),
                le(UInt16(0)), le(UInt16(0)), le(UInt32(0)), le(offset), name
            ))
        }
        let directoryOffset = UInt32(body.count)
        return bytes(
            body, directory,
            le(UInt32(0x0605_4b50)), le(UInt16(0)), le(UInt16(0)),
            le(UInt16(members.count)), le(UInt16(members.count)),
            le(UInt32(directory.count)), le(directoryOffset), le(UInt16(0))
        )
    }

    private static func bytes(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }

    /// Raw DEFLATE of `payload`, from the Compression framework's `COMPRESSION_ZLIB`, which is the format zip uses.
    static func rawDeflate(_ payload: Data) -> Data {
        let input = [UInt8](payload)
        let capacity = input.count + input.count / 10 + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 16)
        defer { scratch.deallocate() }
        let produced = compression_encode_buffer(&output, capacity, input, input.count, scratch, COMPRESSION_ZLIB)
        precondition(produced > 0, "compression_encode_buffer produced nothing")
        return Data(output.prefix(produced))
    }

    /// Bitwise CRC-32, deliberately a different implementation from the reader's table.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
