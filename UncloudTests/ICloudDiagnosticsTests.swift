import Foundation
import Testing
@testable import Uncloud

@Suite("ICloudDiagnostics")
struct ICloudDiagnosticsTests {
    private let arguments = ["-I", "-B", "/x/run_icloudpd.py", "-u", "someone@example.com", "--cookie-directory", "/tmp/session"]

    /// Runs output through the parser the way the helper does, and collects the diagnostics.
    private func diagnostics(_ parts: [(err: Bool, text: String)]) -> ICloudDiagnostics {
        let parser = ICloudOutputParser()
        var diagnostics = ICloudDiagnostics()
        for part in parts {
            parser.feed(Data(part.text.utf8), fromStandardError: part.err).forEach { diagnostics.note($0) }
        }
        parser.finish().forEach { diagnostics.note($0) }
        return diagnostics
    }

    private func out(_ text: String) -> (err: Bool, text: String) { (err: false, text: text) }
    private func err(_ text: String) -> (err: Bool, text: String) { (err: true, text: text) }
    private let log = "2026-10-09 21:40:37 "

    @Test func errorLineIsTheSummary() {
        let found = diagnostics([out("\(log)ERROR    Could not list the albums\n")])
        #expect(found.summary(arguments: arguments) == "Could not list the albums")
    }

    @Test func tracebackLastLineIsTheSummaryWhenThereIsNoErrorLine() {
        let found = diagnostics([err("Traceback (most recent call last):\n  File \"/x/y.py\", line 2, in f\n    g()\nKeyError: 'photo'\n")])
        #expect(found.summary(arguments: arguments) == "KeyError: 'photo'")
    }

    @Test func plainStderrIsTheSummaryWhenNothingElseIsThere() {
        let found = diagnostics([err("Some other problem happened\n")])
        #expect(found.summary(arguments: arguments) == "Some other problem happened")
    }

    @Test func errorLineWinsOverTracebackAndStderr() {
        let found = diagnostics([
            out("\(log)ERROR    Could not list the albums\n"),
            err("Traceback (most recent call last):\n  File \"/x/y.py\", line 2, in f\n    g()\nKeyError: 'photo'\n"),
            err("Some other problem happened\n"),
        ])
        #expect(found.summary(arguments: arguments) == "Could not list the albums")
    }

    @Test func warningsAndIndentedLinesAreNotSummaries() {
        let found = diagnostics([err("/x/getpass.py:9: GetPassWarning: Can not control echo\n    indented detail\n")])
        #expect(found.summary(arguments: arguments) == nil)
    }

    @Test func summaryIsRedactedAndShort() {
        let long = String(repeating: "word ", count: 80)
        let found = diagnostics([out("\(log)ERROR    Login for someone@example.com failed. \(long)\n")])
        let summary = found.summary(arguments: arguments) ?? ""
        #expect(summary.count <= ICloudDiagnostics.maxSummaryLength)
        #expect(summary.hasSuffix("…"))
        #expect(!summary.contains("someone@example.com"))
        #expect(summary.hasPrefix("Login for <apple-id> failed."))
    }

    @Test func redactsAppleIDEmailAndLongTokensInATranscript() {
        let transcript = """
        arguments: -I -B /x/run_icloudpd.py -u someone@example.com --cookie-directory /tmp/session
        exit status: 1

        2026-10-09 21:40:37 INFO     Logging in as someone@example.com
        2026-10-09 21:40:38 DEBUG    token=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop0123456789
        """
        let redacted = ICloudDiagnostics.redact(transcript, arguments: arguments)
        #expect(!redacted.contains("someone@example.com"))
        #expect(!redacted.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop0123456789"))
        #expect(redacted.contains("<apple-id>"))
        #expect(redacted.contains("<redacted>"))
        #expect(redacted.contains("exit status: 1"))
    }

    @Test func keepsFilePathsReadableInATranscript() {
        let path = "/Volumes/X/Photos Archive - Name/2026/02/IMG_7210-77840192.MOV"
        let transcript = """
        2026-02-11 10:02:14 INFO     Downloaded \(path)
        2026-02-11 10:02:15 ERROR    Failed writing \(path): [Errno 28] No space left on device
        """
        let redacted = ICloudDiagnostics.redact(transcript, arguments: arguments)
        #expect(redacted.contains(path))
        #expect(!redacted.contains("<redacted>"))
    }

    @Test func redactsTrustTokensButNotTheLinesAroundThem() {
        let trust = "AQAAAB0ZXN0LXRydXN0LXRva2VuLXZhbHVlLWZvci1yZWRhY3Rpb24tdGVzdGluZw=="
        let transcript = """
        2026-02-11 10:02:14 DEBUG    Set-Cookie: X-APPLE-WEBAUTH-HSA-TRUST=\(trust); Path=/; Secure
        2026-02-11 10:02:14 DEBUG    trust token \(trust) saved to /Users/someone/Library/Caches/session
        """
        let redacted = ICloudDiagnostics.redact(transcript, arguments: arguments)
        #expect(!redacted.contains(trust))
        // The cookie name has no slash, so it joins the token in one redacted run.
        #expect(redacted.contains("<redacted>; Path=/; Secure"))
        #expect(redacted.contains("/Users/someone/Library/Caches/session"))
    }

    @Test func redactsBase64TokensThatContainASlash() {
        // Each side of the slash is 40 or more characters, so both pieces are redacted.
        let token = "dGhpcy1pcy1hLWZha2UtdHJ1c3QtdG9rZW4tZm9yLXRlc3Rz/YW5kLWl0LWhhcy1hLXNsYXNoLWluLWl0LWFuZC1tb3JlLXBhZGRpbmc"
        let redacted = ICloudDiagnostics.redact("token \(token) saved", arguments: arguments)
        #expect(!redacted.contains("dGhpcy1p"))
        #expect(!redacted.contains("YW5kLWl0"))
        #expect(redacted == "token <redacted>/<redacted> saved")
    }

    @Test func redactsEmailsAndAppleIDsNextToPaths() {
        let transcript = "INFO Sharing with friend@example.org, Logging in as someone@example.com, exporting to /Volumes/X/Photos Archive/2026/IMG_7210.MOV"
        let redacted = ICloudDiagnostics.redact(transcript, arguments: arguments)
        #expect(!redacted.contains("someone@example.com"))
        #expect(!redacted.contains("friend@example.org"))
        #expect(redacted.contains("Sharing with <email>, Logging in as <apple-id>"))
        #expect(redacted.contains("/Volumes/X/Photos Archive/2026/IMG_7210.MOV"))
    }

    @Test func exitWithoutClassifiedFailureCarriesTheSummary() {
        let error = ICloudDiagnostics.exitError(status: 1, failure: nil, summary: "KeyError: 'photo'")
        #expect(error == .exited(1, lastMessage: "KeyError: 'photo'"))
        #expect(error.localizedDescription == "The export stopped because of an iCloud error (KeyError: 'photo'). Resume to try again.")
    }

    @Test func exitWithClassifiedFailureIsThatFailure() {
        #expect(ICloudDiagnostics.exitError(status: 1, failure: .network, summary: "x") == .failed(.network))
        #expect(ICloudDiagnostics.exitError(status: 1, failure: .invalidCredentials, summary: nil) == .signInRequired)
    }

    @Test func bridgeErrorKindsMapToLibraryIndexingAndSetup() {
        let indexing = ICloudBridge.error(
            kind: "PyiCloudServiceNotActivatedException",
            message: "('Apple iCloud Photo Library has not finished indexing yet', None)"
        )
        #expect(indexing as? ICloudError == .failed(.libraryIndexing))
        let setup = ICloudBridge.error(
            kind: "PyiCloudServiceNotActivatedException",
            message: "('Apple iCloud setup is not complete. Please log into https://icloud.com/', 'ZONE_NOT_FOUND')"
        )
        #expect(setup as? ICloudError == .failed(.setupIncomplete))
    }
}

@Suite("Transcript buffer")
struct TranscriptBufferTests {
    @Test func keepsTheStartAndTheEndOfALongRunAndMarksTheGap() {
        var buffer = TranscriptBuffer()
        buffer.append(Data("FIRST-LINE\n".utf8))
        let line = Data(String(repeating: "x", count: 1023).utf8) + Data("\n".utf8)
        for _ in 0..<4_000 {  // about 4 MB, well past both limits
            buffer.append(line)
        }
        buffer.append(Data("LAST-LINE\n".utf8))

        let text = String(decoding: buffer.data, as: UTF8.self)
        #expect(text.hasPrefix("FIRST-LINE"))
        #expect(text.hasSuffix("LAST-LINE\n"))
        #expect(text.contains("of output left out"))
        #expect(buffer.data.count <= TranscriptBuffer.headLimit + TranscriptBuffer.tailLimit + 200)
    }

    @Test func shortOutputIsKeptWhole() {
        var buffer = TranscriptBuffer()
        buffer.append(Data("hello\nworld\n".utf8))
        #expect(String(decoding: buffer.data, as: UTF8.self) == "hello\nworld\n")
    }
}
