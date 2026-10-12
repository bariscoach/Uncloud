import Foundation
import Testing
@testable import Uncloud

/// Feeds transcripts to the parser in chunks of several sizes. Every chunking must give the same events.
private func events(
    _ parts: [(err: Bool, text: String)],
    listLibraries: Bool = false
) -> [[ICloudOutputEvent]] {
    [1, 7, Int.max].map { chunk in
        let parser = ICloudOutputParser(expectsLibraryList: listLibraries)
        var events: [ICloudOutputEvent] = []
        for part in parts {
            let bytes = Array(part.text.utf8)
            var start = 0
            while start < bytes.count {
                let end = min(bytes.count, start + chunk)
                events += parser.feed(Data(bytes[start..<end]), fromStandardError: part.err)
                start = end
            }
        }
        return events + parser.finish()
    }
}

private func expectParses(
    _ parts: [(err: Bool, text: String)],
    _ expected: [ICloudOutputEvent],
    listLibraries: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for (index, got) in events(parts, listLibraries: listLibraries).enumerated() {
        #expect(got == expected, "chunking \(index) gave \(got)", sourceLocation: sourceLocation)
    }
}

private func out(_ text: String) -> (err: Bool, text: String) { (err: false, text: text) }
private func err(_ text: String) -> (err: Bool, text: String) { (err: true, text: text) }
private let log = "2026-10-09 21:40:37 "
private let devices = "  a: (•••) •••-••12\n  b: (•••) •••-••34\n"
private let codeOrIndex = "Please enter two-factor authentication code or device index (a..b) to send SMS with a code: "

@Suite("ICloudOutputParser")
struct ICloudOutputParserTests {
    @Test func passwordPromptWithGetpassWarnings() {
        expectParses(
            [err("/opt/x/getpass.py:91: GetPassWarning: Can not control echo on the terminal.\nWarning: Password input may be echoed.\niCloud Password for someone@example.com:")],
            [.passwordPrompt]
        )
    }

    @Test func outputAfterPasswordPromptStartsANewLine() {
        expectParses(
            [err("iCloud Password for someone@example.com:"),
             err("Traceback (most recent call last):\n  File \"/x/base.py\", line 1, in run\n    boom()\nSomeError: boom\n")],
            [.passwordPrompt, .failure(.other("SomeError: boom"))]
        )
    }

    @Test func deviceListThenCodeOrIndexPrompt() {
        expectParses(
            [out("\(log)INFO     Two-factor authentication is required (2fa)\n" + devices + codeOrIndex)],
            [.log(level: "INFO", message: "Two-factor authentication is required (2fa)"),
             .trustedDevices([ICloudTrustedDevice(index: "a", label: "(•••) •••-••12"),
                              ICloudTrustedDevice(index: "b", label: "(•••) •••-••34")]),
             .codePrompt(canRequestSMS: true)]
        )
    }

    @Test func invalidCodeThenPromptAgainWithoutRepeatingDevices() {
        expectParses(
            [out("Invalid code, should be six digits. Try again\n" + codeOrIndex)],
            [.invalidInput("Invalid code, should be six digits. Try again"), .codePrompt(canRequestSMS: true)]
        )
    }

    @Test func otherValidationMessages() {
        expectParses(
            [out("Empty string. Try again\nInvalid index, should be (a..b). Try again\nShould be index (a..b) or six-digit code. Try again\n")],
            [.invalidInput("Empty string. Try again"),
             .invalidInput("Invalid index, should be (a..b). Try again"),
             .invalidInput("Should be index (a..b) or six-digit code. Try again")]
        )
    }

    @Test func plainCodePromptWithoutDeviceList() {
        expectParses([out("Please enter two-factor authentication code: ")], [.codePrompt(canRequestSMS: false)])
    }

    @Test func codePromptFollowedByInvalidCodeOnTheSameLine() {
        expectParses(
            [out("Please enter two-factor authentication code: Invalid code, should be six digits. Try again\n")],
            [.codePrompt(canRequestSMS: false), .invalidInput("Invalid code, should be six digits. Try again")]
        )
    }

    @Test func smsCodePrompt() {
        expectParses([out("Please enter two-factor authentication code that you received over SMS: ")], [.smsCodePrompt])
    }

    @Test func successfulAuthenticationBanner() {
        expectParses(
            [out("\(log)INFO     Great, you're all set up. The script can now be run without \n"
                 + "user interaction until 2FA expires.\n"
                 + "You can set up email notifications for when \n"
                 + "the two-factor authentication expires.\n"
                 + "(Use --help to view information about SMTP options.)\n"
                 + "\(log)INFO     Authentication completed successfully\n")],
            [.authenticated, .authenticated]
        )
    }

    @Test func totalAnnouncedCountUnknownCountAndFirstItem() {
        expectParses(
            [out("\(log)INFO     Downloading 1234 original photos and videos to /x ...\n"
                 + "\(log)INFO     Downloading ??? original,medium photos and videos to /x/y ...\n"
                 + "\(log)INFO     Downloading the first original photo or video to /x ...\n"
                 + "\(log)DEBUG    Downloading /x/2024/IMG_0003.JPG...\n")],
            [.totalAnnounced(1234), .totalAnnounced(nil), .totalAnnounced(nil),
             .log(level: "DEBUG", message: "Downloading /x/2024/IMG_0003.JPG...")]
        )
    }

    @Test func downloadedAlreadyExistsDeduplicatedAndDeleted() {
        expectParses(
            [out("\(log)INFO     Downloaded /x/2024/IMG_0001.JPG\n"
                 + "\(log)DEBUG    /x/2024/IMG_0002.JPG already exists\n"
                 + "\(log)DEBUG    /x/2024/very ... IMG_0004.HEIC already exists\n"
                 + "\(log)DEBUG    /x/2024/IMG_0005.JPG deduplicated\n"
                 + "\(log)INFO     Deleted IMG_0009.JPG in iCloud\n"
                 + "\(log)INFO     All photos and videos have been downloaded\n")],
            [.downloaded(path: "/x/2024/IMG_0001.JPG"),
             .alreadyExists(path: "/x/2024/IMG_0002.JPG"),
             .alreadyExists(path: "/x/2024/very ... IMG_0004.HEIC"),
             .log(level: "DEBUG", message: "/x/2024/IMG_0005.JPG deduplicated"),
             .deletedInICloud(name: "IMG_0009.JPG"),
             .log(level: "INFO", message: "All photos and videos have been downloaded")]
        )
    }

    @Test func albumListFlushedByNextLogLine() {
        expectParses(
            [out("Albums:\nAll Photos\nFavorites\n\u{0020}\n\(log)INFO     Done\n")],
            [.albumList(["All Photos", "Favorites", " "]), .log(level: "INFO", message: "Done")]
        )
    }

    @Test func libraryListAtEndOfOutput() {
        expectParses(
            [out("\(log)INFO     Processing user: someone@example.com\nPrimarySync\nSharedSync-ABCD\n")],
            [.log(level: "INFO", message: "Processing user: someone@example.com"),
             .libraryList(["PrimarySync", "SharedSync-ABCD"])],
            listLibraries: true
        )
    }

    @Test func invalidPasswordIsInvalidCredentials() {
        expectParses(
            [out("\(log)INFO     ('Invalid email/password combination.', PyiCloudAPIResponseException('Invalid', '401'))\n")],
            [.failure(.invalidCredentials)]
        )
    }

    @Test func twoFactorCodeRejected() {
        expectParses([out("\(log)INFO     Failed to verify two-factor authentication code\n")], [.failure(.twoFactorFailed)])
    }

    @Test func sessionReauthenticationIsAnErrorLine() {
        expectParses([out("\(log)ERROR    Session error, re-authenticating...\n")], [.failure(.sessionExpired(needsSignIn: false))])
    }

    @Test func twoStepRequiredFromTraceback() {
        expectParses(
            [err("Traceback (most recent call last):\n  File \"/x/base.py\", line 5, in run\n    raise e\npyicloud_ipd.exceptions.PyiCloud2SARequiredException: Two-step authentication required for account: someone@example.com\n")],
            [.failure(.sessionExpired(needsSignIn: true))]
        )
    }

    @Test func serviceNotActivatedIsSetupIncomplete() {
        expectParses(
            [out("\(log)INFO     Apple iCloud setup is not complete. Please log into https://icloud.com/ to manually finish setting up your iCloud service\n")],
            [.failure(.setupIncomplete)]
        )
    }

    @Test func temporaryRefusalFromApple() {
        expectParses([out("\(log)INFO     Apple iCloud is temporary refusing to serve icloudpd\n")], [.failure(.serviceUnavailable)])
    }

    @Test func connectionErrorFromChainedTraceback() {
        expectParses(
            [err("Traceback (most recent call last):\n  File \"/x/y.py\", line 2, in f\n    g()\n\nDuring handling of the above exception, another exception occurred:\n\nTraceback (most recent call last):\n  File \"/x/z.py\", line 9, in g\n    raise PyiCloudConnectionErrorException(\"Cannot connect to Apple iCloud service\")\npyicloud_ipd.exceptions.PyiCloudConnectionErrorException: Cannot connect to Apple iCloud service\n")],
            [.failure(.network)]
        )
    }

    @Test func authenticationRequiredFromExceptionText() {
        expectParses(
            [err("pyicloud_ipd.exceptions.PyiCloudAPIResponseException: Authentication required for Account. (421)\n")],
            [.failure(.sessionExpired(needsSignIn: true))]
        )
    }

    @Test func unknownErrorLineBecomesOther() {
        expectParses(
            [out("\(log)ERROR    Notification of the required MFA failed\n")],
            [.failure(.other("Notification of the required MFA failed"))]
        )
    }

    @Test func unknownTracebackBecomesOtherWithLastLine() {
        expectParses(
            [err("Traceback (most recent call last):\n  File \"/x/y.py\", line 2, in f\n    g()\nKeyError: 'photo'\n")],
            [.failure(.other("KeyError: 'photo'"))]
        )
    }

    @Test func unrelatedStandardErrorIsALogLine() {
        expectParses([err("Some other warning\n")], [.log(level: "STDERR", message: "Some other warning")])
    }
}
