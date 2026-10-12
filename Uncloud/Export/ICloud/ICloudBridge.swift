import Foundation
import os

/// One request to `photo_bridge.py`. Unset fields are left out of the JSON.
struct ICloudBridgeRequest: Encodable, Sendable {
    var id = 0
    let cmd: String
    var offset: Int?
    var limit: Int?
    var mode: String?
    var ids: [String]?
    var dest: String?
    var layout: String?
    var album: String?
    var xmp: Bool?
    /// Download only: where each ID was last seen, as its rank in icloudpd's (oldest first) order.
    var hints: [String: Int]?
    var target: Int?
}

/// One line from `photo_bridge.py`. Replies to a request carry its `id`; `asset` is an iCloud asset ID.
struct ICloudBridgeMessage: Decodable, Sendable {
    struct Item: Decodable, Sendable, Hashable {
        let id: String
        let filename: String
        let created: String?
        let type: String
        /// The original's bytes.
        let size: Int64?
        /// What a download writes for the item: the original plus any Live Photo movie.
        let bytes: Int64?
        let thumbURL: String?
    }

    let id: Int?
    let event: String
    var count: Int?
    var offset: Int?
    var items: [Item]?
    var albums: [String]?
    var done: Int?
    var total: Int?
    var asset: String?
    var filename: String?
    var path: String?
    var paths: [String]?
    var reason: String?
    var kind: String?
    var message: String?
    var cancelled: Bool?
    /// Stats: the bytes of this request's items so far, each page's item sizes, and whether the walk reached the end.
    var bytes: Int64?
    var sizes: [String: Int64]?
    var complete: Bool?
}

/// A persistent `photo_bridge.py` process for one Apple ID: request/response by ID, plus event
/// streams for downloads. It starts on first use, answers the bridge's password request from the
/// Keychain (or fails with `ICloudError.signInRequired`), and starts again on the next request if
/// it exits. `shutDownAll()` stops every bridge, for sign-out.
///
/// Like `ICloudHelperProcess`, the bridge runs in its own process group so pause (SIGSTOP),
/// resume and termination reach everything it started.
final class ICloudBridge: Sendable {
    private enum Launch {
        case resume(Int)
        case fail(Error)
        case wait
        case start
    }

    private struct State {
        var generation = 0
        /// Set from the first `ready()` that needs a process until `start()` has one, so concurrent
        /// callers don't launch two.
        var isLaunching = false
        var process: Process?
        var input: FileHandle?
        var sources: [DispatchSourceRead] = []
        var openPipes = 0
        var exitStatus: Int32?
        var output = Data()
        var count: Int?
        var isReady = false
        var readyWaiters: [UUID: CheckedContinuation<Int, Error>] = [:]
        /// Downloads whose consumer stopped listening, waiting for the bridge's final reply.
        var abandoned: Set<Int> = []
        var streams: [Int: AsyncThrowingStream<ICloudBridgeMessage, Error>.Continuation] = [:]
        var nextID = 1
        /// Why the current process can't go on, once known.
        var failure: Error?
        var lastMessage: String?
        var didSignalTermination = false
        #if DEBUG
        var transcript = Data()
        #endif
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [String: ICloudBridge]())
    private static let terminateGrace = DispatchTimeInterval.seconds(5)
    /// How long a cancelled download may take to finish its current item before the bridge is stopped.
    static let abandonGrace = DispatchTimeInterval.seconds(15)
    private static let readChunk = 64 * 1024

    let appleID: String
    let executableURL: URL?
    let arguments: [String]
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "ICloudBridge.output")

    init(
        appleID: String,
        executableURL: URL? = ICloudAccount.helperURL,
        arguments: [String]? = nil
    ) {
        self.appleID = appleID
        self.executableURL = executableURL
        self.arguments = arguments ?? ICloudAccount.bridgeArguments(appleID: appleID)
    }

    /// The bridge for an Apple ID, shared by browsing and exports.
    static func shared(appleID: String) -> ICloudBridge {
        registry.withLock { bridges in
            if let bridge = bridges[appleID] {
                return bridge
            }
            let bridge = ICloudBridge(appleID: appleID)
            bridges[appleID] = bridge
            return bridge
        }
    }

    /// Stops every bridge and forgets them, for sign-out.
    static func shutDownAll() {
        let bridges = registry.withLock { bridges in
            defer { bridges = [:] }
            return Array(bridges.values)
        }
        bridges.forEach { $0.terminate() }
    }

    // MARK: - Requests

    /// Starts the bridge if needed and waits until it has signed in. Returns the library's size.
    /// A cancelled caller stops waiting right away; the bridge goes on signing in for the others.
    @discardableResult
    func ready() async throws -> Int {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let launch = state.withLock { state -> Launch in
                    if state.isReady, let count = state.count {
                        return .resume(count)
                    }
                    if Task.isCancelled {
                        return .fail(CancellationError())
                    }
                    state.readyWaiters[id] = continuation
                    guard state.process == nil, !state.isLaunching else { return .wait }
                    state.isLaunching = true
                    return .start
                }
                switch launch {
                case .resume(let count):
                    continuation.resume(returning: count)
                case .fail(let error):
                    continuation.resume(throwing: error)
                case .start:
                    start()
                case .wait:
                    break
                }
            }
        } onCancel: {
            state.withLock { $0.readyWaiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Items `offset..<offset + limit` in icloudpd's order (oldest first).
    func page(offset: Int, limit: Int) async throws -> [ICloudBridgeMessage.Item] {
        for try await message in try await send(ICloudBridgeRequest(cmd: "page", offset: offset, limit: limit)) {
            if message.event == "page" {
                return message.items ?? []
            }
        }
        throw CancellationError()
    }

    /// The library's current size.
    func count() async throws -> Int {
        for try await message in try await send(ICloudBridgeRequest(cmd: "count")) {
            if message.event == "count", let count = message.count {
                state.withLock { $0.count = count }
                ICloudLibrary.cacheLibraryCount(count)
                return count
            }
        }
        throw CancellationError()
    }

    /// The user's album names, without icloudpd's smart albums.
    func albums() async throws -> [String] {
        for try await message in try await send(ICloudBridgeRequest(cmd: "albums")) {
            if message.event == "albums" {
                return message.albums ?? []
            }
        }
        throw CancellationError()
    }

    /// Walks the library from `offset` (icloudpd's order), streaming `statsProgress` with each page's
    /// item sizes, through the final `stats`. Ending the stream early stops the walk after its page.
    func stats(offset: Int) async throws -> AsyncThrowingStream<ICloudBridgeMessage, Error> {
        try await send(ICloudBridgeRequest(cmd: "stats", offset: offset))
    }

    /// Starts a download and streams its events through the final `done`. Ending the stream early
    /// asks the bridge to stop after the current item.
    func download(_ request: ICloudBridgeRequest) async throws -> AsyncThrowingStream<ICloudBridgeMessage, Error> {
        precondition(request.cmd == "download")
        return try await send(request)
    }

    /// Sends a request once the bridge is ready. The stream ends after the request's final
    /// reply, and throws the bridge's error for it.
    func send(_ request: ICloudBridgeRequest) async throws -> AsyncThrowingStream<ICloudBridgeMessage, Error> {
        try await ready()
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ICloudBridgeMessage.self)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.streams[id] = continuation
            return id
        }
        let isDownload = request.cmd == "download"
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                self?.abandon(id, isDownload: isDownload)
            }
        }
        var request = request
        request.id = id
        if !write(request) {
            finish(id, throwing: ICloudError.exited(-1, lastMessage: nil))
        }
        return stream
    }

    /// Pauses the bridge and its children.
    func suspend() {
        sendSignal(SIGSTOP)
    }

    /// Continues after `suspend()`.
    func resume() {
        sendSignal(SIGCONT)
    }

    /// The bridge's process ID while it runs.
    var processIdentifier: Int32? {
        state.withLock { state in
            guard let process = state.process, state.exitStatus == nil, process.processIdentifier > 0 else { return nil }
            return process.processIdentifier
        }
    }

    /// Stops the bridge: closes its input and sends SIGTERM to its process group, then SIGKILL after
    /// 5 seconds. Waiting requests fail; the next request starts a new bridge, which signs in again.
    /// Downloads in progress are left as `.part` files that icloudpd and the bridge both resume.
    func terminate() {
        let generation = state.withLock { state -> Int? in
            guard state.process != nil, state.exitStatus == nil, !state.didSignalTermination else { return nil }
            state.didSignalTermination = true
            if state.failure == nil {
                state.failure = CancellationError()
            }
            try? state.input?.close()
            state.input = nil
            return state.generation
        }
        guard let generation else { return }
        sendSignal(SIGTERM)
        sendSignal(SIGCONT)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminateGrace) { [self] in
            sendSignal(SIGKILL, generation: generation)
        }
    }

    // MARK: - Process

    private func start() {
        guard let executableURL else {
            state.withLock { $0.isLaunching = false }
            failReady(ICloudError.helperMissing)
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let generation = state.withLock { state -> Int in
            state.generation += 1
            state.isLaunching = false
            state.process = process
            state.exitStatus = nil
            state.output = Data()
            state.count = nil
            state.isReady = false
            state.failure = nil
            state.lastMessage = nil
            state.didSignalTermination = false
            #if DEBUG
            state.transcript = Data()
            #endif
            return state.generation
        }
        process.terminationHandler = { [self] process in
            let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
            queue.async { self.processExited(status, generation: generation) }
        }

        do {
            try process.run()
        } catch {
            for handle in [inputPipe.fileHandleForReading, inputPipe.fileHandleForWriting,
                           outputPipe.fileHandleForReading, outputPipe.fileHandleForWriting,
                           errorPipe.fileHandleForReading, errorPipe.fileHandleForWriting] {
                try? handle.close()
            }
            state.withLock { $0.process = nil }
            failReady(error)
            return
        }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        // Writing after the bridge exits must fail with EPIPE, not kill the app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let sources = [
            makeSource(outputPipe.fileHandleForReading, isOutput: true, generation: generation),
            makeSource(errorPipe.fileHandleForReading, isOutput: false, generation: generation),
        ]
        state.withLock { state in
            state.input = inputPipe.fileHandleForWriting
            state.sources = sources
            state.openPipes = sources.count
        }
        sources.forEach { $0.resume() }
    }

    private func makeSource(_ handle: FileHandle, isOutput: Bool, generation: Int) -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self, weak source] in
            var buffer = [UInt8](repeating: 0, count: Self.readChunk)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let chunk = Data(buffer[..<count])
                if isOutput {
                    received(chunk, generation: generation)
                } else {
                    receivedLog(chunk, generation: generation)
                }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                source?.cancel()
            }
        }
        source.setCancelHandler { [self] in
            try? handle.close()
            pipeClosed(generation: generation)
        }
        return source
    }

    /// Runs on `queue`.
    private func received(_ chunk: Data, generation: Int) {
        let lines = state.withLock { state -> [Data] in
            guard state.generation == generation else { return [] }
            state.output.append(chunk)
            var lines: [Data] = []
            while let newline = state.output.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(state.output[state.output.startIndex..<newline])
                state.output.removeSubrange(state.output.startIndex...newline)
            }
            return lines
        }
        let decoder = JSONDecoder()
        for line in lines where !line.isEmpty {
            guard let message = try? decoder.decode(ICloudBridgeMessage.self, from: line) else { continue }
            handle(message, generation: generation)
        }
    }

    /// Runs on `queue`. Keeps the last error line for messages, and a transcript in debug builds.
    private func receivedLog(_ chunk: Data, generation: Int) {
        let text = String(decoding: chunk, as: UTF8.self)
        let lastError = text.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("Error") }
        state.withLock { state in
            guard state.generation == generation else { return }
            #if DEBUG
            state.transcript.append(chunk)
            #endif
            if let lastError {
                state.lastMessage = String(lastError)
            }
        }
    }

    /// Runs on `queue`.
    private func handle(_ message: ICloudBridgeMessage, generation: Int) {
        if let id = message.id {
            let continuation = state.withLock { state -> AsyncThrowingStream<ICloudBridgeMessage, Error>.Continuation? in
                guard state.generation == generation else { return nil }
                if ["error", "page", "count", "albums", "done", "stats"].contains(message.event) {
                    state.abandoned.remove(id)
                }
                return state.streams[id]
            }
            guard let continuation else { return }
            switch message.event {
            case "error":
                finish(id, throwing: Self.error(kind: message.kind, message: message.message))
            case "page", "count", "albums", "done", "stats":
                continuation.yield(message)
                finish(id, throwing: nil)
            default:
                continuation.yield(message)
            }
            return
        }

        switch message.event {
        case "needPassword":
            // The password goes only to the bridge's input, never to a log.
            if let password = ICloudCredentialStore.password(for: appleID),
               let data = try? JSONSerialization.data(withJSONObject: ["password": password]) {
                writeLine(data)
            } else {
                state.withLock { $0.failure = ICloudError.signInRequired }
                terminate()
            }
        case "signInRequired":
            state.withLock { $0.failure = ICloudError.signInRequired }
        case "ready":
            let count = message.count ?? 0
            let waiters = state.withLock { state -> [CheckedContinuation<Int, Error>] in
                guard state.generation == generation else { return [] }
                state.isReady = true
                state.count = count
                defer { state.readyWaiters = [:] }
                return Array(state.readyWaiters.values)
            }
            ICloudLibrary.cacheLibraryCount(count)
            waiters.forEach { $0.resume(returning: count) }
        case "error":
            let error = Self.error(kind: message.kind, message: message.message)
            state.withLock { state in
                if state.failure == nil, !state.isReady {
                    state.failure = error
                }
            }
        default:
            break
        }
    }

    /// Runs on `queue`.
    private func pipeClosed(generation: Int) {
        state.withLock { state in
            if state.generation == generation {
                state.openPipes -= 1
            }
        }
        finishIfDone(generation: generation)
    }

    /// Runs on `queue`.
    private func processExited(_ status: Int32, generation: Int) {
        let sources = state.withLock { state -> [DispatchSourceRead] in
            guard state.generation == generation else { return [] }
            state.exitStatus = status
            state.process?.terminationHandler = nil
            try? state.input?.close()
            state.input = nil
            return state.sources
        }
        // A stray grandchild could hold a pipe open; don't wait on it forever.
        queue.asyncAfter(deadline: .now() + .seconds(2)) {
            sources.forEach { $0.cancel() }
        }
        finishIfDone(generation: generation)
    }

    /// Runs on `queue`. Once the process has exited and its output is read, fails whatever still
    /// waits and resets for a fresh start.
    private func finishIfDone(generation: Int) {
        let ended = state.withLock { state -> (error: Error, waiters: [CheckedContinuation<Int, Error>], streams: [AsyncThrowingStream<ICloudBridgeMessage, Error>.Continuation])? in
            guard state.generation == generation, state.openPipes <= 0, let status = state.exitStatus,
                  state.process != nil else { return nil }
            let error = state.failure ?? ICloudError.exited(status, lastMessage: state.lastMessage)
            #if DEBUG
            HelperTranscript.save(state.transcript, arguments: ["photo_bridge.py"] + Array(arguments.suffix(4)), exitStatus: status)
            state.transcript = Data()
            #endif
            let result = (error, Array(state.readyWaiters.values), Array(state.streams.values))
            state.process = nil
            state.sources = []
            state.readyWaiters = [:]
            state.abandoned = []
            state.streams = [:]
            state.isReady = false
            state.count = nil
            return result
        }
        guard let ended else { return }
        ended.waiters.forEach { $0.resume(throwing: ended.error) }
        ended.streams.forEach { $0.finish(throwing: ended.error) }
    }

    private func failReady(_ error: Error) {
        let waiters = state.withLock { state in
            defer { state.readyWaiters = [:] }
            return Array(state.readyWaiters.values)
        }
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func finish(_ id: Int, throwing error: Error?) {
        let continuation = state.withLock { $0.streams.removeValue(forKey: id) }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    /// The consumer stopped listening: forget the request and ask the bridge to stop a download
    /// after its current item. A bridge that hasn't finished the download after `abandonGrace`
    /// (stuck, or downloading a very large file) is stopped.
    private func abandon(_ id: Int, isDownload: Bool) {
        let generation = state.withLock { state -> Int? in
            guard state.streams.removeValue(forKey: id) != nil else { return nil }
            if isDownload {
                state.abandoned.insert(id)
            }
            return state.generation
        }
        guard let generation else { return }
        write(ICloudBridgeRequest(cmd: "cancel", target: id))
        guard isDownload else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.abandonGrace) { [weak self] in
            guard let self else { return }
            let isStuck = state.withLock { $0.generation == generation && $0.abandoned.contains(id) }
            if isStuck {
                terminate()
            }
        }
    }

    @discardableResult
    private func write(_ request: ICloudBridgeRequest) -> Bool {
        guard let data = try? JSONEncoder().encode(request) else { return false }
        return writeLine(data)
    }

    @discardableResult
    private func writeLine(_ data: Data) -> Bool {
        state.withLock { state in
            guard let input = state.input, state.exitStatus == nil else { return false }
            var bytes = [UInt8](data)
            bytes.append(UInt8(ascii: "\n"))
            let descriptor = input.fileDescriptor
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    @discardableResult
    private func sendSignal(_ number: Int32, generation: Int? = nil) -> Bool {
        state.withLock { state in
            guard let process = state.process, state.exitStatus == nil,
                  generation == nil || generation == state.generation else { return false }
            let pid = process.processIdentifier
            guard pid > 0 else { return false }
            if getpgid(pid) == pid {
                killpg(pid, number)
            } else {
                kill(pid, number)
            }
            return true
        }
    }

    // MARK: - Errors

    /// Maps a bridge error to the errors the rest of the app already handles.
    static func error(kind: String?, message: String?) -> Error {
        let kind = kind ?? "error"
        let message = message ?? ""
        switch kind {
        case "PyiCloudFailedLoginException", "PyiCloud2SARequiredException", "PyiCloudFailedMFAException":
            return ICloudError.signInRequired
        case "badRequest", "albumNotFound", "libraryNotFound":
            return ICloudError.failed(.other(message))
        default:
            let failure = ICloudOutputParser.failure(forException: "\(kind): \(message)")
            switch failure {
            case .invalidCredentials, .twoFactorFailed, .sessionExpired(needsSignIn: true):
                return ICloudError.signInRequired
            default:
                return ICloudError.failed(failure)
            }
        }
    }
}

// MARK: - Browsing

extension ICloudBridgeMessage.Item {
    var asset: ICloudAsset {
        ICloudAsset(
            id: id,
            filename: filename,
            created: created.flatMap { try? Date($0, strategy: .iso8601) },
            isVideo: type == "movie",
            thumbnailURL: thumbURL.flatMap(URL.init(string:)),
            bytes: bytes ?? size
        )
    }
}

/// Feeds the page cache from the bridge.
struct ICloudBridgeFetcher: ICloudPageFetching {
    let bridge: ICloudBridge

    func count() async throws -> Int {
        try await bridge.ready()
        return try await bridge.count()
    }

    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
        try await bridge.page(offset: offset, limit: limit).map(\.asset)
    }
}
