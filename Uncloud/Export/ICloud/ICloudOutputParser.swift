import Foundation

/// One meaningful thing icloudpd said.
enum ICloudOutputEvent: Equatable, Sendable {
    case passwordPrompt
    case trustedDevices([ICloudTrustedDevice])
    case codePrompt(canRequestSMS: Bool)
    case smsCodePrompt
    case invalidInput(String)
    case authenticated
    case totalAnnounced(Int?)
    case downloaded(path: String)
    case alreadyExists(path: String)
    case deletedInICloud(name: String)
    case albumList([String])
    case libraryList([String])
    case failure(ICloudFailure)
    case log(level: String, message: String)
}

/// A trusted phone number offered for two-factor sign-in, such as `("a", "(•••) •••-••12")`.
struct ICloudTrustedDevice: Equatable, Sendable {
    let index: String
    let label: String
}

/// A classified icloudpd error.
enum ICloudFailure: Equatable, Sendable {
    case invalidCredentials
    case twoFactorFailed
    case sessionExpired(needsSignIn: Bool)
    case serviceUnavailable
    /// Apple wants something finished on icloud.com first, usually accepting updated terms.
    case setupIncomplete
    case webAccessDisabled
    case network
    case other(String)

    /// Plain-language text for users.
    var message: String {
        switch self {
        case .invalidCredentials:
            "The Apple ID or password isn’t correct."
        case .twoFactorFailed:
            "The verification code wasn’t accepted. Try again."
        case .sessionExpired(needsSignIn: true):
            "Your iCloud session has expired. Sign in again."
        case .sessionExpired(needsSignIn: false):
            "Your iCloud session expired. Reconnecting…"
        case .serviceUnavailable:
            "iCloud is temporarily unavailable. Try again later."
        case .setupIncomplete:
            "Apple needs you to accept its updated iCloud Terms and Conditions before your photos can be downloaded. Apple shows them only in its own apps: in System Settings, click your name and look for a “Review” banner, or sign in at icloud.com. Uncloud checks again when you come back."
        case .webAccessDisabled:
            "iCloud Photos isn’t available for this Apple ID. Check that iCloud Photos is turned on and that Access iCloud Data on the Web is enabled."
        case .network:
            "Couldn’t reach iCloud. Check your internet connection, then try again."
        case .other(let detail):
            "iCloud reported a problem: \(detail)"
        }
    }
}

/// Feed raw bytes from stdout and stderr; get events back. Handles lines split across chunks, and prompts that have no trailing newline: emit a prompt event as soon as a partial line matches a known prompt.
final class ICloudOutputParser {
    private struct StreamState {
        var partial: [UInt8] = []
        var promptMatched = false
        var skipPromptTail = false
    }

    private enum PromptKind {
        case password
        case code(canRequestSMS: Bool)
        case sms
    }

    private enum Listing {
        case albums
        case libraries
    }

    private static let maxPromptLength = 512

    private var stdout = StreamState()
    private var stderr = StreamState()
    private let expectsLibraryList: Bool
    private var listing: Listing?
    private var listingNames: [String] = []
    private var devices: [ICloudTrustedDevice] = []
    private var inAuthBanner = false
    private var inTraceback = false
    private var pendingException: String?

    /// - Parameter expectsLibraryList: Set for `--list-libraries`, whose output has no header line.
    init(expectsLibraryList: Bool = false) {
        self.expectsLibraryList = expectsLibraryList
    }

    /// Returns the events completed by these bytes.
    func feed(_ data: Data, fromStandardError: Bool) -> [ICloudOutputEvent] {
        var events: [ICloudOutputEvent] = []
        for byte in data {
            if byte == UInt8(ascii: "\n") {
                let line = takeLine(fromStandardError)
                events += handleLine(line, fromStandardError: fromStandardError)
            } else {
                events += appendByte(byte, fromStandardError: fromStandardError)
            }
        }
        return events
    }

    /// Flushes the partial lines and any pending output at end of stream.
    func finish() -> [ICloudOutputEvent] {
        var events = handleLine(takeLine(false), fromStandardError: false)
        events += flushListing()
        events += handleLine(takeLine(true), fromStandardError: true)
        events += flushException()
        return events
    }

    // MARK: - Byte handling

    private func withStream<T>(_ fromStandardError: Bool, _ body: (inout StreamState) -> T) -> T {
        if fromStandardError {
            return body(&stderr)
        }
        return body(&stdout)
    }

    private func takeLine(_ fromStandardError: Bool) -> String {
        let bytes = withStream(fromStandardError) { state -> [UInt8] in
            defer { state = StreamState() }
            return state.partial
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func appendByte(_ byte: UInt8, fromStandardError: Bool) -> [ICloudOutputEvent] {
        let prompt = withStream(fromStandardError) { state -> PromptKind? in
            // The prompt's ": " tail is written with the prompt, so drop it from the next line.
            if state.skipPromptTail {
                if byte == UInt8(ascii: " ") || byte == UInt8(ascii: ":") {
                    return nil
                }
                state.skipPromptTail = false
            }
            state.partial.append(byte)
            guard !state.promptMatched, state.partial.count <= Self.maxPromptLength,
                  let kind = Self.matchPrompt(String(decoding: state.partial, as: UTF8.self)) else {
                return nil
            }
            state.promptMatched = true
            state.skipPromptTail = true
            state.partial.removeAll()
            return kind
        }
        guard let prompt else {
            return []
        }
        return promptEvents(prompt)
    }

    private func promptEvents(_ prompt: PromptKind) -> [ICloudOutputEvent] {
        switch prompt {
        case .password:
            return [.passwordPrompt]
        case .sms:
            return [.smsCodePrompt]
        case .code(let canRequestSMS):
            var events: [ICloudOutputEvent] = []
            if !devices.isEmpty {
                events.append(.trustedDevices(devices))
            }
            devices = []
            events.append(.codePrompt(canRequestSMS: canRequestSMS))
            return events
        }
    }

    private static func matchPrompt(_ text: String) -> PromptKind? {
        // Every prompt ends in a colon, so a shared prefix such as "Please enter two-factor authentication code" waits for it.
        guard text.hasSuffix(":") else {
            return nil
        }
        if text.hasPrefix("iCloud Password for ") {
            return .password
        }
        var trimmed = text
        while let last = trimmed.last, last == " " || last == ":" {
            trimmed.removeLast()
        }
        switch trimmed {
        case "Please enter two-factor authentication code":
            return .code(canRequestSMS: false)
        case "Please enter two-factor authentication code that you received over SMS":
            return .sms
        default:
            break
        }
        if trimmed.hasPrefix("Please enter two-factor authentication code or device index (")
            && trimmed.hasSuffix("to send SMS with a code") {
            return .code(canRequestSMS: true)
        }
        return nil
    }

    // MARK: - Line handling

    private func handleLine(_ rawLine: String, fromStandardError: Bool) -> [ICloudOutputEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard !line.isEmpty else {
            return []
        }
        return fromStandardError ? handleStandardErrorLine(line) : handleStandardOutputLine(line)
    }

    private func handleStandardErrorLine(_ line: String) -> [ICloudOutputEvent] {
        // getpass warns before prompting for the password, and PyInstaller's bootloader repeats
        // Python's exit; neither is news.
        if line.contains("GetPassWarning") || line.contains("Password input may be echoed")
            || line.contains("Can not control echo") || line.contains("fallback_getpass(")
            || line.hasPrefix("[PYI-") {
            return []
        }
        // In a chained traceback the last exception is the one that ended the run.
        if line.hasPrefix("During handling of the above exception")
            || line.hasPrefix("The above exception was the direct cause") {
            pendingException = nil
            inTraceback = false
            return []
        }
        var events: [ICloudOutputEvent] = []
        if pendingException != nil && !Self.isTracebackContinuation(line) {
            events += flushException()
        }
        if line.hasPrefix("Traceback (most recent call last):") {
            inTraceback = true
            return events
        }
        if inTraceback {
            if !Self.isTracebackContinuation(line) {
                inTraceback = false
                pendingException = line
            }
            return events
        }
        return events + classify(line, level: "STDERR")
    }

    private func handleStandardOutputLine(_ line: String) -> [ICloudOutputEvent] {
        if let entry = Self.parseLogLine(line) {
            return flushListing() + classify(entry.message, level: entry.level)
        }
        if inAuthBanner {
            // The "Great, you're all set up" message continues on raw lines until "(Use --help".
            if line.hasPrefix("(Use --help") {
                inAuthBanner = false
            }
            return []
        }
        if let device = Self.parseDevice(line) {
            devices.append(device)
            return []
        }
        if Self.isInvalidInput(line) {
            return flushListing() + [.invalidInput(line)]
        }
        if line == "Albums:" {
            let events = flushListing()
            listing = .albums
            return events
        }
        if listing == nil && expectsLibraryList {
            listing = .libraries
        }
        if listing != nil {
            listingNames.append(line)
            return []
        }
        return [.log(level: "", message: line)]
    }

    private func flushListing() -> [ICloudOutputEvent] {
        defer {
            listing = nil
            listingNames = []
        }
        switch listing {
        case .albums?:
            return [.albumList(listingNames)]
        case .libraries?:
            return [.libraryList(listingNames)]
        case nil:
            return []
        }
    }

    private func flushException() -> [ICloudOutputEvent] {
        guard let line = pendingException else {
            return []
        }
        pendingException = nil
        // SIGINT from terminate() isn't an iCloud problem.
        if line == "KeyboardInterrupt" {
            return [.log(level: "STDERR", message: line)]
        }
        return [.failure(Self.failure(forException: line))]
    }

    private static func isTracebackContinuation(_ line: String) -> Bool {
        line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("Traceback (most recent call last)")
            || line.hasPrefix("During handling of the above exception")
            || line.hasPrefix("The above exception was the direct cause")
    }

    // MARK: - Classification

    private func classify(_ message: String, level: String) -> [ICloudOutputEvent] {
        if level == "INFO", let total = Self.announcedTotal(message) {
            return [total]
        }
        if level == "INFO", message.hasPrefix("Downloaded ") {
            return [.downloaded(path: String(message.dropFirst("Downloaded ".count)))]
        }
        if level == "DEBUG", message.hasSuffix(" already exists") {
            return [.alreadyExists(path: String(message.dropLast(" already exists".count)))]
        }
        if level == "INFO", message.hasPrefix("Deleted "), message.hasSuffix(" in iCloud") {
            let name = message.dropFirst("Deleted ".count).dropLast(" in iCloud".count)
            return [.deletedInICloud(name: String(name))]
        }
        if level != "DEBUG", let failure = Self.classifyFailure(message) {
            return [.failure(failure)]
        }
        if message.hasPrefix("Authentication completed successfully") {
            return [.authenticated]
        }
        if message.hasPrefix("Great, you're all set up") {
            inAuthBanner = true
            return [.authenticated]
        }
        if level == "ERROR" {
            return [.failure(.other(message))]
        }
        return [.log(level: level, message: message)]
    }

    private static func announcedTotal(_ message: String) -> ICloudOutputEvent? {
        let prefix = "Downloading "
        guard message.hasPrefix(prefix), message.hasSuffix(" ..."), message.contains(" to ") else {
            return nil
        }
        let rest = message.dropFirst(prefix.count)
        if rest.hasPrefix("the first ") {
            return .totalAnnounced(nil)
        }
        return .totalAnnounced(Int(rest.prefix { $0 != " " }))
    }

    private static func classifyFailure(_ text: String) -> ICloudFailure? {
        let rules: [(String, ICloudFailure)] = [
            ("Invalid email/password combination.", .invalidCredentials),
            ("Invalid username/password combination.", .invalidCredentials),
            ("Failed to verify two-factor authentication code", .twoFactorFailed),
            ("Failed to verify two-step authentication code", .twoFactorFailed),
            ("Failed to send two-factor authentication code", .twoFactorFailed),
            ("Failed to send two-step authentication code", .twoFactorFailed),
            ("Invalid authentication token.", .sessionExpired(needsSignIn: false)),
            ("Invalid global session", .sessionExpired(needsSignIn: false)),
            ("Session error, re-authenticating...", .sessionExpired(needsSignIn: false)),
            ("Two-step authentication required for account", .sessionExpired(needsSignIn: true)),
            ("Authentication required for Account.", .sessionExpired(needsSignIn: true)),
            ("Apple iCloud setup is not complete", .setupIncomplete),
            ("Webservice not available", .webAccessDisabled),
            ("Apple iCloud is temporary refusing to serve icloudpd", .serviceUnavailable),
            ("Service Unavailable", .serviceUnavailable),
            ("Cannot connect to Apple iCloud service", .network),
            ("Failed to establish a new connection", .network),
            ("Max retries exceeded", .network),
        ]
        if let rule = rules.first(where: { text.contains($0.0) }) {
            return rule.1
        }
        if text.contains("Apple insists on using") || text.contains("Failed to initiate srp authentication.") {
            return .other(text)
        }
        return nil
    }

    /// Classifies a traceback's final line, which looks like `pyicloud_ipd.exceptions.Name: message`.
    /// The bridge reports errors the same way, as `Name: message`.
    static func failure(forException line: String) -> ICloudFailure {
        if let failure = classifyFailure(line) {
            return failure
        }
        let name = line.prefix { $0 != ":" }.split(separator: ".").last.map(String.init) ?? ""
        switch name {
        case "PyiCloudConnectionErrorException":
            return .network
        case "PyiCloudServiceUnavailableException":
            return .serviceUnavailable
        case "PyiCloudFailedMFAException":
            return .twoFactorFailed
        case "PyiCloud2SARequiredException":
            return .sessionExpired(needsSignIn: true)
        case "PyiCloudServiceNotActivatedException", "PyiCloudServiceNotActivatedErrror":
            return .setupIncomplete
        default:
            return .other(line)
        }
    }

    // MARK: - Line shapes

    /// Splits `YYYY-MM-DD HH:MM:SS LEVEL    message`.
    private static func parseLogLine(_ line: String) -> (level: String, message: String)? {
        let bytes = Array(line.utf8)
        guard bytes.count > 20 else {
            return nil
        }
        let digitIndexes = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        guard digitIndexes.allSatisfy({ bytes[$0] >= 0x30 && bytes[$0] <= 0x39 }),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: " "), bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: " ") else {
            return nil
        }
        var index = 20
        let levelStart = index
        while index < bytes.count && bytes[index] != UInt8(ascii: " ") {
            index += 1
        }
        let level = String(decoding: bytes[levelStart..<index], as: UTF8.self)
        guard !level.isEmpty, level.allSatisfy({ $0.isUppercase }) else {
            return nil
        }
        while index < bytes.count && bytes[index] == UInt8(ascii: " ") {
            index += 1
        }
        return (level, String(decoding: bytes[index...], as: UTF8.self))
    }

    /// Matches `  a: (•••) •••-••12`.
    private static func parseDevice(_ line: String) -> ICloudTrustedDevice? {
        let bytes = Array(line.utf8)
        guard bytes.count >= 5, bytes[0] == UInt8(ascii: " "), bytes[1] == UInt8(ascii: " "),
              bytes[2] >= 0x61, bytes[2] <= 0x7A, bytes[3] == UInt8(ascii: ":"),
              bytes[4] == UInt8(ascii: " ") else {
            return nil
        }
        return ICloudTrustedDevice(
            index: String(decoding: [bytes[2]], as: UTF8.self),
            label: String(decoding: bytes[5...], as: UTF8.self)
        )
    }

    private static func isInvalidInput(_ line: String) -> Bool {
        line.hasPrefix("Empty string. Try again")
            || line.hasPrefix("Invalid index, should be (")
            || line.hasPrefix("Invalid code, should be six digits")
            || line.hasPrefix("Should be index (")
    }
}
