import CryptoKit
import Darwin
import Foundation

/// SHA-256 of a file read straight from disk for a verify pass: the file bypasses the page cache, read-ahead is on, and
/// one buffer is reused for the whole file. It returns the same digest as `FileHasher.sha256(of:)`.
enum SequentialFileReader {
    /// SHA-256 of a file as lowercase hex. Throws CancellationError when the current task is cancelled between buffers.
    static func sha256(of url: URL, bufferSize: Int = 4 << 20) throws -> String {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        _ = fcntl(descriptor, F_RDAHEAD, 1)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, buffer, bufferSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return hasher.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }
}
