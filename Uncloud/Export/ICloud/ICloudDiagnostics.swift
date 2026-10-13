import AppKit
import Foundation

/// What a helper printed that explains how it failed. Built from parser events, so it sees the lines
/// the app classifies: the last ERROR line, else the last traceback exception line, else the last
/// stderr line. The summary shown to users is redacted and short.
struct ICloudDiagnostics: Sendable {
    /// The longest summary, ellipsis included.
    static let maxSummaryLength = 160

    /// The last classified failure icloudpd or the bridge reported.
    private(set) var failure: ICloudFailure?
    private(set) var errorLine: String?
    private(set) var exceptionLine: String?
    private(set) var stderrLine: String?

    mutating func note(_ event: ICloudOutputEvent) {
        switch event {
        case .failure(let failure):
            self.failure = failure
        case .log(let level, let message):
            switch level {
            case "ERROR", "CRITICAL":
                errorLine = message
            case "EXCEPTION":
                exceptionLine = message
            case "STDERR":
                // Indented lines are traceback details and "Warning" lines are usually noise.
                if !message.hasPrefix(" ") && !message.contains("Warning") {
                    stderrLine = message
                }
            default:
                break
            }
        default:
            break
        }
    }

    /// The detail for an error message: one line, redacted, at most `maxSummaryLength` characters.
    /// Nil when nothing useful was printed.
    func summary(arguments: [String]) -> String? {
        guard let line = errorLine ?? exceptionLine ?? stderrLine else { return nil }
        let collapsed = Self.redact(line, arguments: arguments)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > Self.maxSummaryLength else { return collapsed }
        return String(collapsed.prefix(Self.maxSummaryLength - 1)) + "…"
    }

    /// The error for a helper or bridge that exited without an error of its own. A classified failure
    /// wins; otherwise the exit is reported with the summary, if there is one.
    static func exitError(status: Int32, failure: ICloudFailure?, summary: String?) -> ICloudError {
        switch failure {
        case .invalidCredentials?, .twoFactorFailed?, .sessionExpired(needsSignIn: true)?:
            .signInRequired
        case let failure?:
            .failed(failure)
        case nil:
            .exited(status, lastMessage: summary)
        }
    }

    /// Removes the Apple ID (the value after `-u` in the arguments), email addresses and long tokens.
    /// A token is 40 or more characters of base64 or URL-safe characters. `/` is not one of them, so file
    /// paths such as `/Volumes/X/Photos Archive/2026/IMG_7210.MOV` stay readable. A base64 token that
    /// contains `/` is redacted in each piece of 40 or more characters.
    static func redact(_ text: String, arguments: [String]) -> String {
        var result = text
        if let index = arguments.firstIndex(of: "-u"), arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            result = result.replacingOccurrences(of: arguments[index + 1], with: "<apple-id>")
        }
        result = result.replacingOccurrences(
            of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            with: "<email>",
            options: .regularExpression
        )
        return result.replacingOccurrences(of: #"[A-Za-z0-9+=_\-]{40,}"#, with: "<redacted>", options: .regularExpression)
    }
}

/// Keeps the last few helper and bridge transcripts in `<Caches>/helper-logs/`, redacted, in every
/// build. The password never appears: it only goes to the helper's input, and the output never echoes it.
/// A helper's output kept for its transcript, bounded so a long export can't grow it without limit.
/// The start (sign-in and setup problems) and the most recent part (where a run fails) are kept.
struct TranscriptBuffer: Sendable {
    static let headLimit = 256 * 1024
    static let tailLimit = 768 * 1024

    private var head = Data()
    private var tail = Data()
    private var droppedBytes = 0

    mutating func append(_ chunk: Data) {
        var rest = chunk
        if head.count < Self.headLimit {
            let take = min(Self.headLimit - head.count, rest.count)
            head.append(rest.prefix(take))
            rest = rest.dropFirst(take)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        // Trim in batches rather than on every chunk.
        if tail.count > Self.tailLimit * 2 {
            trimTail()
        }
    }

    /// The kept output, with a marker where the middle was left out.
    var data: Data {
        var copy = self
        copy.trimTail()
        guard copy.droppedBytes > 0 else { return copy.head + copy.tail }
        let marker = "\n… \(ByteCountFormatter.string(fromByteCount: Int64(copy.droppedBytes), countStyle: .file)) of output left out …\n"
        return copy.head + Data(marker.utf8) + copy.tail
    }

    private mutating func trimTail() {
        guard tail.count > Self.tailLimit else { return }
        droppedBytes += tail.count - Self.tailLimit
        tail = Data(tail.suffix(Self.tailLimit))
    }
}

enum HelperTranscript {
    private static let keep = 10

    /// The folder for transcripts, created if it's missing.
    static func folder() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = caches.appending(path: "helper-logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Opens the transcript folder in Finder.
    @MainActor
    static func revealFolder() {
        guard let folder = folder() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    static func save(_ output: Data, arguments: [String], exitStatus: Int32?) {
        guard let folder = folder() else { return }

        var text = "arguments: \(arguments.joined(separator: " "))\nexit status: \(exitStatus.map(String.init) ?? "?")\n\n"
        text += String(decoding: output, as: UTF8.self)
        text = ICloudDiagnostics.redact(text, arguments: arguments)

        let stamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        try? text.write(to: folder.appending(path: "\(stamp)-\(UUID().uuidString.prefix(4)).log"), atomically: true, encoding: .utf8)

        let logs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for old in logs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
