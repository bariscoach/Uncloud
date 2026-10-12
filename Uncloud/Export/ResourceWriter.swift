import Foundation
import os
import Photos

/// Streams one asset resource to disk, downloading it from iCloud if needed.
/// Data goes to a hidden `.partial` file that's renamed only once complete.
enum ResourceWriter {
    /// Returns the file's SHA-256, after re-reading it from disk to confirm it matches what Photos delivered.
    @discardableResult
    static func write(_ resource: PHAssetResource, to url: URL) async throws -> String {
        let partial = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).partial")
        guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: partial])
        }
        let hasher = StreamingHasher()
        do {
            let handle = try FileHandle(forWritingTo: partial)
            do {
                try await download(resource, into: handle, hasher: hasher)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.moveItem(at: partial, to: url)
            let streamed = hasher.finalizeHex()
            do {
                let written = try FileHasher.sha256(of: url)
                guard written == streamed else {
                    throw ChecksumError.mismatch(filename: url.lastPathComponent)
                }
                return written
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func download(_ resource: PHAssetResource, into handle: FileHandle, hasher: StreamingHasher) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let request = DataRequest()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    do {
                        try handle.write(contentsOf: data)
                        hasher.update(data)
                    } catch {
                        request.fail(with: error)
                    }
                } completionHandler: { error in
                    if let error = request.writeError ?? error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                request.started(id)
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
    }
}

/// Tracks one in-flight Photos data request so it can be cancelled from any thread.
private final class DataRequest: Sendable {
    private struct State {
        var id: PHAssetResourceDataRequestID?
        var isCancelled = false
        var writeError: (any Error)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var writeError: (any Error)? {
        state.withLock { $0.writeError }
    }

    func started(_ id: PHAssetResourceDataRequestID) {
        let cancelNow = state.withLock { state in
            state.id = id
            return state.isCancelled || state.writeError != nil
        }
        if cancelNow {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    /// Stops the download after a disk write fails; that error is reported instead of the cancellation.
    func fail(with error: any Error) {
        let id = state.withLock { state in
            if state.writeError == nil {
                state.writeError = error
            }
            return state.id
        }
        if let id {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    func cancel() {
        let id = state.withLock { state in
            state.isCancelled = true
            return state.id
        }
        if let id {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }
}
