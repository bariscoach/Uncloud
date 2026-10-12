import CryptoKit
import Foundation
import os

/// Accumulates a SHA-256 digest from chunks delivered on any thread.
final class StreamingHasher: Sendable {
    // SHA256 is a value type, so the unchecked lock is safe here.
    private let state = OSAllocatedUnfairLock(uncheckedState: SHA256())

    func update(_ data: Data) {
        state.withLockUnchecked { $0.update(data: data) }
    }

    /// The digest of everything fed so far, as lowercase hex. Finishing consumes the hasher's state.
    func finalizeHex() -> String {
        let digest = state.withLockUnchecked { $0.finalize() }
        return hexString(digest)
    }
}

enum FileHasher {
    /// Chunk size used when reading files from disk.
    private static let chunkSize = 1 << 20

    /// SHA-256 of a file on disk, read in 1 MB chunks. Throws CancellationError if the current task is cancelled.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }
}

enum ChecksumError: LocalizedError {
    case mismatch(filename: String)

    var errorDescription: String? {
        switch self {
        case .mismatch(let filename):
            "“\(filename)” didn’t match the original after copying."
        }
    }
}

private func hexString(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", Int($0)) }.joined()
}
