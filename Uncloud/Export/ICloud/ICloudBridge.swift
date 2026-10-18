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
    /// Download only: where each ID was last seen, as its rank in icloudpd's order (rank 0 is the newest).
    var hints: [String: Int]?
    /// Download only: the first rank visited; items ranked below it are skipped without being paged.
    var startRank: Int?
    /// allExcept downloads only: the walk ends when it reaches this asset (not visited), or at the library's end.
    var stopAt: String?
    /// Cancel, pause and resume: the request they apply to.
    var target: Int?
}

/// One line from `photo_bridge.py`. Replies to a request carry its `id`; `asset` is an iCloud asset ID.
struct ICloudBridgeMessage: Decodable, Sendable {
    struct Item: Decodable, Sendable, Hashable {
        let id: String
        /// Position in icloudpd's walk (rank 0 is the newest item). Nil from a bridge too old to say.
        var rank: Int?
        let filename: String
        let created: String?
        /// When the item was added to the library, the order the walk uses. Nil from a bridge too old to say.
        let added: String?
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
    /// Download events: the item's rank in icloudpd's walk (rank 0 is the newest).
    var rank: Int?
    var filename: String?
    /// Download events: the item's first file, as an absolute, untruncated path.
    var path: String?
    /// `downloaded`: the files this request wrote; `skipped`: the files found already there.
    var paths: [String]?
    /// `downloaded` and `skipped`: every file the item has on disk now (written or found), plus its
    /// XMP sidecar when there is one. What an `icloud-id:` manifest record lists.
    var files: [String]?
    var reason: String?
    var kind: String?
    var message: String?
    var cancelled: Bool?
    /// `done` (and a run-ending `error`): the request's item counts.
    var downloaded: Int?
    var skipped: Int?
    var failed: Int?
    /// Stats: the bytes of this request's items so far, each page's item sizes (and the page's items
    /// without a size), and whether the walk reached the end.
    var bytes: Int64?
    var sizes: [String: Int64]?
    var unsized: [String]?
    var complete: Bool?
}

/// A download sent to the bridge: its request ID, for pausing it, and its events.
struct ICloudBridgeDownload: Sendable {
    let id: Int
    let messages: AsyncThrowingStream<ICloudBridgeMessage, Error>

    /// The same events, typed. Ends after `.done`. A run-ending failure is thrown, not yielded: Apple's
    /// throttle (HTTP 503) as `ICloudError.failed(.serviceUnavailable)` and a lost connection as
    /// `ICloudError.failed(.network)`, both retryable by `AutoResumePolicy`; the item the bridge was on
    /// when it happened gets no event and isn't finished.
    var events: AsyncCompactMapSequence<AsyncThrowingStream<ICloudBridgeMessage, Error>, ICloudBridgeDownloadEvent> {
        messages.compactMap { ICloudBridgeDownloadEvent($0) }
    }
}

/// What to download through the bridge, for `ICloudBridge.download(_:)`.
///
/// Ranks are positions in icloudpd's walk: rank 0 is the newest item, and a photo added to iCloud is
/// inserted at rank 0, shifting every other rank up by one.
struct ICloudBridgeDownloadOptions: Sendable, Equatable {
    enum Mode: String, Sendable {
        /// Only the items in `ids`.
        case only
        /// Everything except the items in `ids`. Excluded items cost no file check.
        case allExcept
    }

    enum Layout: String, Sendable {
        /// `DEST/YYYY/MM/NAME`, icloudpd's `--folder-structure {:%Y/%m}`.
        case month
        /// `DEST/NAME` for the items of `album`.
        case album
        /// `DEST/NAME` for the whole library, icloudpd's `--folder-structure none` ("All in One Folder").
        case none
    }

    var mode: Mode
    var ids: [String] = []
    var destination: URL
    var layout: Layout = .month
    /// Required with `.album`.
    var album: String?
    var writesSidecars = false
    /// `.only`: where each ID was last seen, so the bridge fetches those pages instead of walking.
    var rankHints: [String: Int]?
    /// The first rank visited: the walk pages from here, and items ranked below it (and their hints)
    /// are never visited. 0 walks everything.
    var startRank = 0
    /// `.allExcept`: the walk ends when it reaches this asset, without visiting it (or at the end of the
    /// library, when it isn't there). nil walks to the end.
    var stopAt: String?

    var request: ICloudBridgeRequest {
        ICloudBridgeRequest(
            cmd: "download",
            mode: mode.rawValue,
            ids: ids,
            dest: destination.path(percentEncoded: false),
            layout: layout.rawValue,
            album: album,
            xmp: writesSidecars,
            hints: rankHints,
            startRank: startRank > 0 ? startRank : nil,
            stopAt: stopAt
        )
    }
}

/// One finished item of a bridge download.
struct ICloudBridgeItemResult: Sendable, Equatable {
    /// The iCloud asset ID.
    let asset: String
    /// Its rank in icloudpd's walk at the time of this download; nil from an older bridge.
    let rank: Int?
    let filename: String
    /// The files this download wrote (`.downloaded`) or found already there (`.skipped`), as absolute paths.
    let paths: [String]
    /// Every file the item has on disk now, written or found, plus its XMP sidecar: the paths an
    /// `icloud-id:<asset>` manifest record lists.
    let files: [String]
}

/// A typed event of a bridge download; see `ICloudBridgeDownload.events`.
enum ICloudBridgeDownloadEvent: Sendable, Equatable {
    /// Items finished so far, of the items this request visits (its total can shrink or grow).
    case progress(done: Int, total: Int)
    case downloaded(ICloudBridgeItemResult)
    case skipped(ICloudBridgeItemResult)
    case failed(asset: String, rank: Int?, filename: String, reason: String)
    case done(downloaded: Int, skipped: Int, failed: Int, cancelled: Bool)

    /// Nil for messages that aren't download events.
    init?(_ message: ICloudBridgeMessage) {
        switch message.event {
        case "progress":
            self = .progress(done: message.done ?? 0, total: message.total ?? 0)
        case "downloaded", "skipped":
            guard let asset = message.asset else { return nil }
            let paths = message.paths ?? message.path.map { [$0] } ?? []
            let result = ICloudBridgeItemResult(
                asset: asset,
                rank: message.rank,
                filename: message.filename ?? (paths.first as NSString?)?.lastPathComponent ?? asset,
                paths: paths,
                files: message.files ?? paths
            )
            self = message.event == "downloaded" ? .downloaded(result) : .skipped(result)
        case "failed":
            guard let asset = message.asset else { return nil }
            self = .failed(asset: asset, rank: message.rank, filename: message.filename ?? asset,
                           reason: message.reason ?? "iCloud reported a problem.")
        case "done":
            self = .done(downloaded: message.downloaded ?? 0, skipped: message.skipped ?? 0,
                         failed: message.failed ?? 0, cancelled: message.cancelled ?? false)
        default:
            return nil
        }
    }
}

/// A persistent `photo_bridge.py` process for one Apple ID: request/response by ID, plus event
/// streams for downloads. It starts on first use, answers the bridge's password request from the
/// Keychain (or fails with `ICloudError.signInRequired`), and starts again on the next request if
/// it exits. `shutDownAll()` stops every bridge, for sign-out.
///
/// Browsing, the size scan and exports share the bridge, so it's never paused with a signal: a
/// download is paused and resumed with requests of its own while browsing goes on. A cancelled
/// download or walk stops by itself, between chunks or pages. The bridge is stopped only when it
/// then also stops answering pings (see `Timing`); everything waiting on it fails with
/// `ICloudError.interrupted`, and the next request starts a fresh one. Like `ICloudHelperProcess`,
/// the bridge runs in its own process group so termination reaches everything it started.
final class ICloudBridge: Sendable {
    /// How a cancelled download or walk is watched until the bridge reports that it ended.
    struct Timing: Sendable {
        /// How long it may take to end before the bridge is pinged.
        var abandonGrace: Duration = .seconds(2)
        /// How long a ping may go unanswered before the bridge counts as stuck and is stopped.
        var pingTimeout: Duration = .seconds(30)
        /// Between pings while the request is still ending.
        var pingInterval: Duration = .seconds(2)
    }

    private enum Launch {
        case resume(Int)
        case fail(Error)
        case wait
        case start
    }

    private struct PingTimeout: Error {}

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
        /// Downloads and walks whose consumer stopped listening, waiting for the bridge's final reply.
        var abandoned: Set<Int> = []
        var streams: [Int: AsyncThrowingStream<ICloudBridgeMessage, Error>.Continuation] = [:]
        /// `waitUntilEnded` callers by request ID; called with true once the request ends.
        var endWaiters: [Int: [UUID: @Sendable (Bool) -> Void]] = [:]
        var nextID = 1
        /// Why the current process can't go on, once known.
        var failure: Error?
        /// What the bridge's stderr said, for an error when it exits without one of its own.
        var diagnostics = ICloudDiagnostics()
        var didSignalTermination = false
        /// Everything the bridge printed on stderr, saved redacted when it exits; see `HelperTranscript`.
        var transcript = TranscriptBuffer()
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [String: ICloudBridge]())
    /// Every bridge whose process runs, shared or not, for `ICloudProcesses.shutDownAll`.
    private static let running = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: ICloudBridge]())
    private static let terminateGrace = DispatchTimeInterval.seconds(5)
    private static let readChunk = 64 * 1024
    /// Requests the bridge stops by itself, between chunks or pages, when they're cancelled.
    private static let longCommands: Set<String> = ["download", "stats"]
    /// Events that end a request.
    private static let finalEvents: Set<String> = ["error", "page", "count", "albums", "done", "stats", "pong"]

    let appleID: String
    let executableURL: URL?
    let arguments: [String]
    let timing: Timing
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Reads the bridge's stderr; only touched on `queue`, and reset for each process.
    private let logParser = OSAllocatedUnfairLock(uncheckedState: ICloudOutputParser())
    private let queue = DispatchQueue(label: "ICloudBridge.output")

    init(
        appleID: String,
        executableURL: URL? = ICloudAccount.helperURL,
        arguments: [String]? = nil,
        timing: Timing = Timing()
    ) {
        self.appleID = appleID
        self.executableURL = executableURL
        self.arguments = arguments ?? ICloudAccount.bridgeArguments(appleID: appleID)
        self.timing = timing
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

    /// Bridges whose process is running.
    static var runningBridges: [ICloudBridge] {
        running.withLock { Array($0.values) }
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
    /// asks the bridge to stop the download, which it does after the chunk in progress. A throttle or
    /// lost connection ends the stream with a retryable error instead (see `ICloudBridgeDownload.events`).
    func download(_ request: ICloudBridgeRequest) async throws -> ICloudBridgeDownload {
        precondition(request.cmd == "download")
        let (id, messages) = try await start(request)
        return ICloudBridgeDownload(id: id, messages: messages)
    }

    /// Starts a download described by `options`; see `download(_:)` with a request.
    func download(_ options: ICloudBridgeDownloadOptions) async throws -> ICloudBridgeDownload {
        try await download(options.request)
    }

    /// Sends a request once the bridge is ready. The stream ends after the request's final
    /// reply, and throws the bridge's error for it.
    func send(_ request: ICloudBridgeRequest) async throws -> AsyncThrowingStream<ICloudBridgeMessage, Error> {
        try await start(request).stream
    }

    private func start(_ request: ICloudBridgeRequest) async throws -> (id: Int, stream: AsyncThrowingStream<ICloudBridgeMessage, Error>) {
        try await ready()
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ICloudBridgeMessage.self)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.streams[id] = continuation
            return id
        }
        let isLong = Self.longCommands.contains(request.cmd)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                self?.abandon(id, isLong: isLong)
            }
        }
        var request = request
        request.id = id
        if !write(request) {
            finish(id, throwing: ICloudError.exited(-1, lastMessage: nil))
        }
        return (id, stream)
    }

    /// Holds a download between chunks or items. Browsing goes on meanwhile.
    func pauseDownload(_ id: Int) {
        write(ICloudBridgeRequest(cmd: "pause", target: id))
    }

    /// Continues a download held by `pauseDownload(_:)`.
    func resumeDownload(_ id: Int) {
        write(ICloudBridgeRequest(cmd: "resume", target: id))
    }

    /// Waits up to `timeout` until request `id` has ended in the bridge, such as a cancelled download
    /// that stops after its chunk, or the bridge has exited. True if it ended in time.
    @discardableResult
    func waitUntilEnded(_ id: Int, timeout: Duration) async -> Bool {
        let waiter = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Bool) -> Void = { ended in
                let isFirst = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if isFirst {
                    continuation.resume(returning: ended)
                }
            }
            let isWaiting = state.withLock { state -> Bool in
                guard state.process != nil, state.exitStatus == nil,
                      state.streams[id] != nil || state.abandoned.contains(id) else { return false }
                state.endWaiters[id, default: [:]][waiter] = resume
                return true
            }
            guard isWaiting else {
                resume(true)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                _ = self?.state.withLock { $0.endWaiters[id]?.removeValue(forKey: waiter) }
                resume(false)
            }
        }
    }

    /// The bridge's process ID while it runs.
    var processIdentifier: Int32? {
        state.withLock { state in
            guard let process = state.process, state.exitStatus == nil, process.processIdentifier > 0 else { return nil }
            return process.processIdentifier
        }
    }

    /// Stops the bridge: closes its input and sends SIGCONT and SIGTERM to its process group, then
    /// SIGKILL after 5 seconds. Waiting requests fail with `reason`; the next request starts a new
    /// bridge, which signs in again. With `generation`, only that process is stopped, not a newer one.
    func terminate(reason: Error = CancellationError()) {
        terminate(generation: nil, reason: reason)
    }

    private func terminate(generation expected: Int?, reason: Error) {
        let generation = state.withLock { state -> Int? in
            guard state.process != nil, state.exitStatus == nil, !state.didSignalTermination,
                  expected == nil || expected == state.generation else { return nil }
            state.didSignalTermination = true
            if state.failure == nil {
                state.failure = reason
            }
            try? state.input?.close()
            state.input = nil
            return state.generation
        }
        guard let generation else { return }
        // A stopped process acts on SIGTERM only once it continues.
        sendSignal(SIGCONT, generation: generation)
        sendSignal(SIGTERM, generation: generation)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminateGrace) { [self] in
            sendSignal(SIGKILL, generation: generation)
        }
    }

    /// Sends SIGKILL to the bridge's process group at once, for app shutdown after `terminate()`.
    func kill() {
        sendSignal(SIGKILL)
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

        logParser.withLockUnchecked { $0 = ICloudOutputParser() }
        let generation = state.withLock { state -> Int in
            state.generation += 1
            state.isLaunching = false
            state.process = process
            state.exitStatus = nil
            state.output = Data()
            state.count = nil
            state.isReady = false
            state.failure = nil
            state.diagnostics = ICloudDiagnostics()
            state.didSignalTermination = false
            state.transcript = TranscriptBuffer()
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
        Self.running.withLock { $0[ObjectIdentifier(self)] = self }
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

    /// Runs on `queue`. Reads stderr through the output parser, so the bridge's errors and tracebacks
    /// are classified as icloudpd's are, and keeps the transcript.
    private func receivedLog(_ chunk: Data, generation: Int) {
        let events = logParser.withLockUnchecked { $0.feed(chunk, fromStandardError: true) }
        state.withLock { state in
            guard state.generation == generation else { return }
            state.transcript.append(chunk)
            events.forEach { state.diagnostics.note($0) }
        }
    }

    /// Runs on `queue`.
    private func handle(_ message: ICloudBridgeMessage, generation: Int) {
        if let id = message.id {
            let isFinal = Self.finalEvents.contains(message.event)
            // A final reply ends the request in one step, so a consumer that stops listening at the
            // same moment finds nothing left to abandon (and nothing for a watchdog to wait for).
            let (continuation, waiters) = state.withLock { state -> (AsyncThrowingStream<ICloudBridgeMessage, Error>.Continuation?, [@Sendable (Bool) -> Void]) in
                guard state.generation == generation else { return (nil, []) }
                guard isFinal else { return (state.streams[id], []) }
                state.abandoned.remove(id)
                let waiters = state.endWaiters.removeValue(forKey: id).map { Array($0.values) } ?? []
                return (state.streams.removeValue(forKey: id), waiters)
            }
            waiters.forEach { $0(true) }
            guard let continuation else { return }
            switch message.event {
            case "error":
                continuation.finish(throwing: Self.error(kind: message.kind, message: message.message))
            case _ where isFinal:
                continuation.yield(message)
                continuation.finish()
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
        typealias Ended = (
            error: Error,
            waiters: [CheckedContinuation<Int, Error>],
            streams: [AsyncThrowingStream<ICloudBridgeMessage, Error>.Continuation],
            endWaiters: [@Sendable (Bool) -> Void]
        )
        let ended = state.withLock { state -> Ended? in
            guard state.generation == generation, state.openPipes <= 0, let status = state.exitStatus,
                  state.process != nil else { return nil }
            // Stderr's last lines are read to the end only now, when the pipes have closed.
            logParser.withLockUnchecked { $0.finish() }.forEach { state.diagnostics.note($0) }
            let error: Error = state.failure ?? ICloudDiagnostics.exitError(
                status: status,
                failure: state.diagnostics.failure,
                summary: state.diagnostics.summary(arguments: arguments)
            )
            HelperTranscript.save(state.transcript.data, arguments: arguments, exitStatus: status)
            state.transcript = TranscriptBuffer()
            let result = (error, Array(state.readyWaiters.values), Array(state.streams.values),
                          state.endWaiters.values.flatMap(\.values))
            state.process = nil
            state.sources = []
            state.readyWaiters = [:]
            state.abandoned = []
            state.streams = [:]
            state.endWaiters = [:]
            state.isReady = false
            state.count = nil
            return result
        }
        guard let ended else { return }
        Self.running.withLock { running in
            if running[ObjectIdentifier(self)] === self {
                running[ObjectIdentifier(self)] = nil
            }
        }
        ended.endWaiters.forEach { $0(true) }
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
        let (continuation, waiters) = state.withLock { state in
            (state.streams.removeValue(forKey: id), state.endWaiters.removeValue(forKey: id).map { Array($0.values) } ?? [])
        }
        waiters.forEach { $0(true) }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    /// The consumer stopped listening: forget the request, and ask the bridge to stop a download or
    /// walk, which it does after its current chunk or page. Until the bridge reports the end, a
    /// watchdog pings it now and then; only a bridge that stops answering is stopped.
    private func abandon(_ id: Int, isLong: Bool) {
        let generation = state.withLock { state -> Int? in
            guard state.streams.removeValue(forKey: id) != nil else { return nil }
            if isLong {
                state.abandoned.insert(id)
            } else {
                // The bridge answers a short request anyway; nothing waits for it any more.
                state.endWaiters.removeValue(forKey: id)?.values.forEach { $0(true) }
            }
            return state.generation
        }
        guard let generation else { return }
        write(ICloudBridgeRequest(cmd: "cancel", target: id))
        guard isLong else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.watch(abandoned: id, generation: generation)
        }
    }

    private func isAbandoned(_ id: Int, generation: Int) -> Bool {
        state.withLock { $0.generation == generation && $0.exitStatus == nil && $0.abandoned.contains(id) }
    }

    /// Pings the bridge while abandoned request `id` hasn't ended; stops a bridge that doesn't answer.
    private func watch(abandoned id: Int, generation: Int) async {
        try? await Task.sleep(for: timing.abandonGrace)
        while isAbandoned(id, generation: generation) {
            if await !ping(generation: generation, timeout: timing.pingTimeout) {
                if isAbandoned(id, generation: generation) {
                    terminate(generation: generation, reason: ICloudError.interrupted)
                }
                return
            }
            try? await Task.sleep(for: timing.pingInterval)
        }
    }

    /// Asks the bridge's request loop for a pong. False only when it doesn't answer within `timeout`;
    /// a bridge that exits meanwhile, or is a newer process, counts as answering.
    private func ping(generation: Int, timeout: Duration) async -> Bool {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ICloudBridgeMessage.self)
        let id = state.withLock { state -> Int? in
            guard state.generation == generation, state.exitStatus == nil, state.process != nil else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.streams[id] = continuation
            return id
        }
        guard let id else { return true }
        guard write(ICloudBridgeRequest(id: id, cmd: "ping")) else {
            finish(id, throwing: nil)
            return true
        }
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(id, throwing: PingTimeout())
        }
        defer { timer.cancel() }
        do {
            for try await message in stream where message.event == "pong" {
                return true
            }
            return true
        } catch {
            return !(error is PingTimeout)
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

    /// Signals the bridge's process group while its process runs. `Process.isRunning` turns false
    /// as soon as the process is reaped, before `processExited` records it, which keeps a reused
    /// process ID from being signalled in between.
    @discardableResult
    private func sendSignal(_ number: Int32, generation: Int? = nil) -> Bool {
        state.withLock { state in
            guard let process = state.process, state.exitStatus == nil, process.isRunning,
                  generation == nil || generation == state.generation else { return false }
            let pid = process.processIdentifier
            guard pid > 0 else { return false }
            if getpgid(pid) == pid {
                killpg(pid, number)
            } else {
                Darwin.kill(pid, number)
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
        // What ends a bridge download early, as it ends an icloudpd run: Apple's throttle and a lost
        // connection. Mapped by kind, whatever the message, so automatic resume always sees them.
        case "PyiCloudServiceUnavailableException":
            return ICloudError.failed(.serviceUnavailable)
        case "PyiCloudConnectionErrorException":
            return ICloudError.failed(.network)
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
            bytes: bytes ?? size,
            added: added.flatMap { try? Date($0, strategy: .iso8601) }
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
