import Foundation
import os

enum ICloudError: LocalizedError, Equatable {
    case helperMissing
    case signInRequired
    case failed(ICloudFailure)
    case exited(Int32, lastMessage: String?)
    /// The bridge stopped answering and was restarted; whatever it was doing can be tried again.
    case interrupted

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "The iCloud downloader is missing from Uncloud. Reinstall the app, then try again."
        case .signInRequired:
            "Sign in to iCloud again to continue."
        case .failed(let failure):
            failure.message
        case .exited(_, let detail?):
            "The iCloud download stopped: \(detail)\(detail.hasSuffix(".") ? "" : ".") Choose Resume to try again."
        case .exited(let status, nil):
            "The iCloud download stopped unexpectedly (code \(status))."
        case .interrupted:
            "The connection to iCloud was interrupted. Choose Resume to continue."
        }
    }
}

/// Runs one icloudpd invocation and turns its output into events.
///
/// The helper starts in its own process group, so signals reach PyInstaller's
/// bootloader and the Python process it spawns alike.
final class ICloudHelperProcess: Sendable {
    private struct State {
        var process: Process?
        var input: FileHandle?
        var continuation: AsyncStream<ICloudOutputEvent>.Continuation?
        var sources: [DispatchSourceRead] = []
        var openPipes = 0
        var exitStatus: Int32?
        var exitWaiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]
        /// The helper's process group, when it leads one; it can outlive the helper.
        var processGroup: pid_t?
        var isTerminating = false
        var didSignalTermination = false
        var diagnostics = ICloudDiagnostics()
    }

    private static let terminateGrace = DispatchTimeInterval.seconds(5)
    private static let readChunk = 64 * 1024
    /// Every helper whose process runs, for `ICloudProcesses.shutDownAll`.
    private static let running = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: ICloudHelperProcess]())

    /// Helpers whose process is running.
    static var runningHelpers: [ICloudHelperProcess] {
        running.withLock { Array($0.values) }
    }

    let arguments: [String]
    let executableURL: URL?
    /// Placed before `arguments`; for the bundled runtime, the Python flags and launcher script.
    let leadingArguments: [String]
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let parser: OSAllocatedUnfairLock<ICloudOutputParser>
    /// Reads both pipes and handles exit in order, so events keep their arrival order.
    private let queue = DispatchQueue(label: "ICloudHelperProcess.output")
    /// Everything the helper printed, saved redacted when it finishes; see `HelperTranscript`.
    private let transcript = OSAllocatedUnfairLock(initialState: TranscriptBuffer())

    init(
        arguments: [String],
        executableURL: URL? = ICloudAccount.helperURL,
        leadingArguments: [String] = ICloudAccount.helperLeadingArguments
    ) {
        self.arguments = arguments
        self.executableURL = executableURL
        self.leadingArguments = leadingArguments
        parser = OSAllocatedUnfairLock(
            uncheckedState: ICloudOutputParser(expectsLibraryList: arguments.contains("--list-libraries"))
        )
    }

    /// The flags every run needs: the account, console prompts, and the app's session directory.
    static func commonArguments(appleID: String) -> [String] {
        [
            "-u", appleID,
            "--password-provider", "console",
            "--mfa-provider", "console",
            "--cookie-directory", ICloudAccount.sessionDirectory.path,
            "--no-progress-bar",
        ]
    }

    /// The exit status once the helper has exited; 128 + signal number if a signal ended it.
    var exitStatus: Int32? {
        state.withLock { $0.exitStatus }
    }

    /// The helper's process ID while it runs; it also leads the helper's process group.
    var processIdentifier: Int32? {
        state.withLock { state in
            guard let process = state.process, state.exitStatus == nil, process.processIdentifier > 0 else {
                return nil
            }
            return process.processIdentifier
        }
    }

    /// True once `terminate()` has been called.
    var isTerminating: Bool {
        state.withLock { $0.isTerminating }
    }

    /// The last failure icloudpd reported.
    var lastFailure: ICloudFailure? {
        state.withLock { $0.diagnostics.failure }
    }

    /// The line that best explains a failure: the last ERROR line, else a traceback's last line,
    /// else the last stderr line. Redacted and at most 160 characters; see `ICloudDiagnostics`.
    var diagnosticSummary: String? {
        state.withLock { $0.diagnostics.summary(arguments: arguments) }
    }

    /// Launches the helper. The stream finishes after it exits and both pipes are closed;
    /// cancelling the consumer terminates it.
    func start() throws -> AsyncStream<ICloudOutputEvent> {
        guard let executableURL else {
            throw ICloudError.helperMissing
        }
        let (stream, continuation) = AsyncStream.makeStream(of: ICloudOutputEvent.self)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = leadingArguments + arguments
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
        process.terminationHandler = { [self] process in
            let status = process.terminationReason == .uncaughtSignal
                ? 128 + process.terminationStatus
                : process.terminationStatus
            queue.async { self.processExited(status) }
        }

        let alreadyStarted = state.withLock { state -> Bool in
            guard state.process == nil else {
                return true
            }
            state.process = process
            state.continuation = continuation
            return false
        }
        guard !alreadyStarted else {
            preconditionFailure("ICloudHelperProcess.start() called twice")
        }

        do {
            try process.run()
        } catch {
            state.withLock {
                $0.process = nil
                $0.continuation = nil
            }
            for handle in [inputPipe.fileHandleForReading, inputPipe.fileHandleForWriting,
                           outputPipe.fileHandleForReading, outputPipe.fileHandleForWriting,
                           errorPipe.fileHandleForReading, errorPipe.fileHandleForWriting] {
                try? handle.close()
            }
            continuation.finish()
            throw error
        }

        Self.running.withLock { $0[ObjectIdentifier(self)] = self }
        let pid = process.processIdentifier
        if pid > 0, getpgid(pid) == pid {
            state.withLock { $0.processGroup = pid }
        }
        // The child has its own copies; the parent keeps only its ends.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        // Writing after the helper exits must fail with EPIPE, not kill the app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let sources = [
            makeSource(outputPipe.fileHandleForReading, fromStandardError: false),
            makeSource(errorPipe.fileHandleForReading, fromStandardError: true),
        ]
        let terminateEarly = state.withLock { state -> Bool in
            state.input = inputPipe.fileHandleForWriting
            state.sources = sources
            state.openPipes = sources.count
            return state.isTerminating
        }
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                self?.terminate()
            }
        }
        sources.forEach { $0.resume() }
        if terminateEarly {
            terminate()
        }
        return stream
    }

    /// Writes one line to the helper's stdin. The text is never logged.
    func send(_ line: String) {
        state.withLock { state in
            guard let input = state.input, state.exitStatus == nil else {
                return
            }
            var bytes = Array(line.utf8)
            bytes.append(UInt8(ascii: "\n"))
            let descriptor = input.fileDescriptor
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// Pauses the helper and its children.
    func suspend() {
        sendSignal(SIGSTOP)
    }

    /// Continues after `suspend()`.
    func resume() {
        sendSignal(SIGCONT)
    }

    /// Stops the helper: closes stdin and sends SIGCONT and SIGTERM to its process group, then SIGKILL
    /// after 5 seconds to whatever of the group is still running, even if the helper itself exited.
    ///
    /// icloudpd has no SIGINT handling of its own, and PyInstaller's bootloader often leaves its
    /// extracted copy (about 24 MB) in the temporary folder after SIGINT; after SIGTERM it cleans up.
    /// Downloads in progress are `.part` files that icloudpd resumes next time.
    func terminate() {
        let shouldSignal = state.withLock { state -> Bool in
            state.isTerminating = true
            try? state.input?.close()
            state.input = nil
            // Sources exist once start() has launched the process.
            guard !state.didSignalTermination, !state.sources.isEmpty,
                  state.exitStatus == nil else {
                return false
            }
            state.didSignalTermination = true
            return true
        }
        guard shouldSignal else {
            return
        }
        // A stopped (paused) process acts on SIGTERM only once it continues.
        sendSignal(SIGCONT)
        sendSignal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminateGrace) { [self] in
            kill()
        }
    }

    /// Sends SIGKILL to the helper's process group now, even if the helper itself exited: a process
    /// it started may still be running in its group. A group ID isn't reused while the group has
    /// members, so this reaches only them. For app shutdown after `terminate()`.
    func kill() {
        if !sendSignal(SIGKILL), let group = state.withLock({ $0.processGroup }) {
            killpg(group, SIGKILL)
        }
    }

    /// Waits for the helper to exit and returns its status; -1 if it never started.
    func waitUntilExit() async -> Int32 {
        await waitForExit(timeout: nil) ?? -1
    }

    /// Waits up to `timeout` for the helper to exit. Returns its status, or nil if it's still
    /// running or never started. Unlike most waits, it doesn't end early when the task is cancelled,
    /// so a cancelled export can still wait for its helper to stop.
    func waitUntilExit(timeout: Duration) async -> Int32? {
        await waitForExit(timeout: timeout)
    }

    private func waitForExit(timeout: Duration?) async -> Int32? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> Int32?? in
                if let status = state.exitStatus {
                    return .some(status)
                }
                guard state.process != nil else {
                    return .some(nil)
                }
                state.exitWaiters[id] = continuation
                return .none
            }
            if case .some(let status) = immediate {
                continuation.resume(returning: status)
                return
            }
            if let timeout {
                let nanoseconds = Int(min(timeout / .nanoseconds(1), Double(Int.max)))
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [self] in
                    state.withLock { $0.exitWaiters.removeValue(forKey: id) }?.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Signals

    /// Sends a signal while the helper is still running. Returns false if it already exited.
    /// `Process.isRunning` turns false as soon as the process is reaped, before `processExited`
    /// records it, which keeps a reused process ID from being signalled in between.
    @discardableResult
    private func sendSignal(_ number: Int32) -> Bool {
        state.withLock { state in
            guard let process = state.process, state.exitStatus == nil, process.isRunning else {
                return false
            }
            let pid = process.processIdentifier
            guard pid > 0 else {
                return false
            }
            if getpgid(pid) == pid {
                killpg(pid, number)
            } else {
                Darwin.kill(pid, number)
            }
            return true
        }
    }

    // MARK: - Output

    private func makeSource(_ handle: FileHandle, fromStandardError: Bool) -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self, weak source] in
            var buffer = [UInt8](repeating: 0, count: Self.readChunk)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let chunk = Data(buffer[..<count])
                transcript.withLock { $0.append(chunk) }
                deliver(parser.withLockUnchecked {
                    $0.feed(Data(buffer[..<count]), fromStandardError: fromStandardError)
                })
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                source?.cancel()
            }
        }
        source.setCancelHandler { [self] in
            try? handle.close()
            pipeClosed()
        }
        return source
    }

    /// Runs on `queue`.
    private func deliver(_ events: [ICloudOutputEvent]) {
        guard !events.isEmpty else {
            return
        }
        let continuation = state.withLock { state in
            for event in events {
                state.diagnostics.note(event)
            }
            return state.continuation
        }
        events.forEach { continuation?.yield($0) }
    }

    /// Runs on `queue`.
    private func pipeClosed() {
        state.withLock { $0.openPipes -= 1 }
        finishIfDone()
    }

    /// Runs on `queue`.
    private func processExited(_ status: Int32) {
        Self.running.withLock { running in
            if running[ObjectIdentifier(self)] === self {
                running[ObjectIdentifier(self)] = nil
            }
        }
        let (waiters, sources) = state.withLock { state in
            state.exitStatus = status
            state.process?.terminationHandler = nil
            try? state.input?.close()
            state.input = nil
            defer { state.exitWaiters = [:] }
            return (Array(state.exitWaiters.values), state.sources)
        }
        waiters.forEach { $0.resume(returning: status) }
        // A stray grandchild could hold a pipe open; don't wait on it forever.
        queue.asyncAfter(deadline: .now() + .seconds(2)) {
            sources.forEach { $0.cancel() }
        }
        finishIfDone()
    }

    /// Runs on `queue`.
    private func finishIfDone() {
        let isDone = state.withLock { $0.openPipes == 0 && $0.exitStatus != nil && $0.continuation != nil }
        guard isDone else {
            return
        }
        deliver(parser.withLockUnchecked { $0.finish() })
        HelperTranscript.save(transcript.withLock { $0.data }, arguments: arguments, exitStatus: exitStatus)
        let continuation = state.withLock { state in
            defer {
                state.continuation = nil
                state.sources = []
            }
            return state.continuation
        }
        continuation?.finish()
    }
}

// MARK: - Runs without UI

extension ICloudHelperProcess {
    /// Starts a run that can't ask the user anything. A password prompt is answered from the
    /// Keychain; any other prompt stops the run with `ICloudError.signInRequired`. A non-zero
    /// exit throws, and a run stopped with `terminate()` or by cancellation throws `CancellationError`.
    static func nonInteractive(
        arguments: [String],
        appleID: String,
        executableURL: URL? = ICloudAccount.helperURL,
        leadingArguments: [String] = ICloudAccount.helperLeadingArguments
    ) -> (helper: ICloudHelperProcess, events: AsyncThrowingStream<ICloudOutputEvent, any Error>) {
        let helper = ICloudHelperProcess(
            arguments: arguments,
            executableURL: executableURL,
            leadingArguments: leadingArguments
        )
        let events = AsyncThrowingStream<ICloudOutputEvent, any Error> { continuation in
            let task = Task {
                do {
                    let events = try helper.start()
                    var answeredPassword = false
                    var needsSignIn = false
                    for await event in events {
                        if needsSignIn {
                            continue
                        }
                        switch event {
                        case .passwordPrompt where !answeredPassword:
                            if let password = ICloudCredentialStore.password(for: appleID) {
                                answeredPassword = true
                                helper.send(password)
                            } else {
                                needsSignIn = true
                            }
                        case .passwordPrompt, .trustedDevices, .codePrompt, .smsCodePrompt:
                            needsSignIn = true
                        case .log(_, let message) where Self.announcesTwoFactor(message):
                            needsSignIn = true
                        default:
                            continuation.yield(event)
                        }
                        if needsSignIn {
                            helper.terminate()
                        }
                    }
                    let status = await helper.waitUntilExit()
                    if needsSignIn {
                        throw ICloudError.signInRequired
                    }
                    if helper.isTerminating || Task.isCancelled {
                        throw CancellationError()
                    }
                    if status != 0 {
                        throw ICloudDiagnostics.exitError(
                            status: status,
                            failure: helper.lastFailure,
                            summary: helper.diagnosticSummary
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                helper.terminate()
            }
        }
        return (helper, events)
    }

    private static func announcesTwoFactor(_ message: String) -> Bool {
        message.hasPrefix("Two-factor authentication is required")
            || message.hasPrefix("Two-step authentication is required")
    }

}
