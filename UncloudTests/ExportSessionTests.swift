import Foundation
import Testing
@testable import Uncloud

@Suite("ExportSession")
struct ExportSessionTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-10-12T14:03:27Z")!

    private static func encode(_ session: ExportSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session)
    }

    private static func decode(_ data: Data) throws -> ExportSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportSession.self, from: data)
    }

    private static func fullSession() -> ExportSession {
        var session = ExportSession(
            trigger: .autoResume,
            startedAt: start,
            appVersion: "0.1.4 (14)",
            launchID: UUID(),
            source: .iCloud,
            account: ExportSession.accountHash(appleID: "someone@example.com"),
            layout: .month,
            writesSidecars: true,
            selection: ExportSession.SelectionSummary(kind: .allExcept, count: 93_015)
        )
        session.attempt = 2
        session.kind = .export
        session.updatedAt = start.addingTimeInterval(600)
        session.endedAt = start.addingTimeInterval(900)
        session.libraryCount = 93_015
        session.driveCheck = ExportSession.DriveCheckSummary(
            onDrive: 9_207, toGo: 83_808, missing: 0, damaged: 2, setAside: 2, untracked: 0, mode: .quick, seconds: 0.8
        )
        session.continuation = ExportSession.Continuation(strategy: .fromRank, startRank: 9_007, fallbackReason: nil)
        session.counts = ExportSession.Counts(exported: 1_204, skipped: 9_207, failed: 1, bytesWritten: 4_100_000_000)
        session.result = ExportSession.Result(status: .failed, reason: "Apple is limiting downloads", retryable: true)
        session.autoResume = ExportSession.AutoResumeNote(attempt: 1, resumeAt: start.addingTimeInterval(1_200))
        session.failures = [ExportSession.Failure(name: "IMG_0042.HEIC", reason: "Timed out")]
        return session
    }

    @Test func roundTripKeepsEveryField() throws {
        let session = Self.fullSession()
        let decoded = try Self.decode(Self.encode(session))
        #expect(decoded == session)
    }

    @Test func newSessionStartsRunningAndChainsToItself() {
        let session = ExportSession(
            trigger: .manual,
            startedAt: Self.start,
            appVersion: "0.1.4 (14)",
            launchID: UUID(),
            source: .photosLibrary,
            layout: .place,
            writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: .everything, count: 12)
        )
        #expect(session.schema == ExportSession.currentSchema)
        #expect(session.chainID == session.id)
        #expect(session.attempt == 1)
        #expect(session.result.status == .running)
        #expect(!session.isFinished)
        #expect(session.account == nil)
    }

    @Test func unknownKeysAreIgnored() throws {
        let session = Self.fullSession()
        var object = try JSONSerialization.jsonObject(with: Self.encode(session)) as! [String: Any]
        object["someFutureField"] = ["nested": [1, 2, 3]]
        object["anotherField"] = "value"
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try Self.decode(data)
        #expect(decoded == session)
    }

    @Test func newerSchemaDecodesAsReadOnly() throws {
        let session = Self.fullSession()
        var object = try JSONSerialization.jsonObject(with: Self.encode(session)) as! [String: Any]
        object["schema"] = 2
        let decoded = try Self.decode(try JSONSerialization.data(withJSONObject: object))

        #expect(decoded.schema == 2)
        #expect(decoded.isReadOnly)
        #expect(!session.isReadOnly)
        #expect(decoded.id == session.id)
    }

    @Test func fileNeverHoldsAnAppleID() throws {
        let session = Self.fullSession()
        let text = String(decoding: try Self.encode(session), as: UTF8.self)
        #expect(!text.contains("someone@example.com"))
        #expect(!text.contains("example.com"))
        #expect(!text.contains("@"))
    }

    @Test func accountHashIsPseudonymousAndNormalized() {
        let hash = ExportSession.accountHash(appleID: "a@b.c")
        #expect(hash.count == 16)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(hash != "a@b.c")
        // The same account gives the same label whatever the case or surrounding spaces.
        #expect(ExportSession.accountHash(appleID: "  A@B.C \n") == hash)
        #expect(ExportSession.accountHash(appleID: "other@b.c") != hash)
    }

    /// An older Uncloud reading a session from a newer one, such as layout "flat" or a source it doesn't have:
    /// the file still decodes, with the field nil, and rewriting it keeps the original value.
    @Test func unknownLayoutOrSourceStillDecodesAndSurvivesARewrite() throws {
        var object = try JSONSerialization.jsonObject(with: Self.encode(Self.fullSession())) as! [String: Any]
        object["layout"] = "spiral"
        object["source"] = "googlePhotos"
        let decoded = try Self.decode(try JSONSerialization.data(withJSONObject: object))

        #expect(decoded.layout == nil)
        #expect(decoded.source == nil)
        #expect(decoded.layoutName == "spiral")
        #expect(decoded.sourceName == "googlePhotos")
        #expect(decoded.counts.exported == 1_204)

        let rewritten = try JSONSerialization.jsonObject(with: Self.encode(decoded)) as! [String: Any]
        #expect(rewritten["layout"] as? String == "spiral")
        #expect(rewritten["source"] as? String == "googlePhotos")
    }

    @Test func flatLayoutRoundTripsByItsRawValue() throws {
        var session = Self.fullSession()
        session.layout = .flat
        let object = try JSONSerialization.jsonObject(with: Self.encode(session)) as! [String: Any]
        #expect(object["layout"] as? String == "flat")
        #expect(try Self.decode(Self.encode(session)).layout == .flat)
    }

    /// The store lists such a file instead of skipping it, and the interrupted sweep rewrites it without
    /// losing the unknown layout.
    @Test func storeListsAndSweepsASessionWithAnUnknownLayout() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            var session = Self.fullSession()
            session.result = ExportSession.Result(status: .running)
            session.endedAt = nil
            session.autoResume = nil
            try store.write(session)
            let file = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).first)
            let url = directory.appending(path: file)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            object["layout"] = "flat-v2"
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            #expect(store.list().count == 1)
            #expect(store.list().first?.layout == nil)
            let changed = try store.markInterrupted(currentLaunch: UUID(), now: session.updatedAt.addingTimeInterval(3600))
            #expect(changed == 1)
            let swept = try #require(store.list().first)
            #expect(swept.result.status == .interrupted)
            #expect(swept.layoutName == "flat-v2")
        }
    }
}
