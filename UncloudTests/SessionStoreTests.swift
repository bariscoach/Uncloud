import Foundation
import Testing
@testable import Uncloud

@Suite("SessionStore")
struct SessionStoreTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-10-12T14:03:27Z")!

    private static func session(
        startedAt: Date = start,
        id: UUID = UUID(),
        chainID: UUID? = nil,
        launchID: UUID = UUID(),
        status: ExportSession.Status = .completed
    ) -> ExportSession {
        var session = ExportSession(
            id: id,
            chainID: chainID,
            trigger: .manual,
            startedAt: startedAt,
            appVersion: "0.1.4 (14)",
            launchID: launchID,
            source: .iCloud,
            layout: .month,
            writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: .everything, count: 10)
        )
        session.updatedAt = startedAt
        session.endedAt = startedAt
        session.result = ExportSession.Result(status: status)
        return session
    }

    private static func jsonFiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    @Test func destinationSessionsLiveInsidePhotoExportFolder() throws {
        try withTemporaryDirectory { destination in
            let store = SessionStore(destination: destination)
            try store.write(Self.session())
            let folder = destination.appending(path: ".photo-export/sessions", directoryHint: .isDirectory)
            #expect(Self.jsonFiles(in: folder).count == 1)
        }
    }

    @Test func fileNameIsUTCWithoutColonsAndSortsInTimeOrder() {
        let early = Self.session(startedAt: Self.start, id: UUID(uuidString: "1F3A9C00-0000-0000-0000-000000000001")!)
        let later = Self.session(startedAt: Self.start.addingTimeInterval(3_600), id: UUID())

        let name = SessionStore.baseName(for: early)
        #expect(name.hasPrefix("2026-10-12T14-03-27Z-1f3a9c"))
        #expect(!name.contains(":"))
        #expect(SessionStore.baseName(for: early) < SessionStore.baseName(for: later))
    }

    @Test func listReturnsSessionsOldestFirst() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let late = Self.session(startedAt: Self.start.addingTimeInterval(7_200))
            let early = Self.session(startedAt: Self.start)
            try store.write(late)
            try store.write(early)
            #expect(store.list().map(\.id) == [early.id, late.id])
        }
    }

    @Test func rewritingASessionReplacesItsFile() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            var session = Self.session()
            try store.write(session)
            session.counts.exported = 42
            session.updatedAt = Self.start.addingTimeInterval(30)
            try store.write(session)

            #expect(Self.jsonFiles(in: directory).count == 1)
            #expect(store.list().count == 1)
            #expect(store.list().first?.counts.exported == 42)
        }
    }

    @Test func clashingNamesGetASuffixAndBothSurvive() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            // Same start second and same first six hex digits of the id: the names would collide.
            let first = Self.session(id: UUID(uuidString: "1F3A9C00-0000-0000-0000-000000000001")!)
            let second = Self.session(id: UUID(uuidString: "1F3A9C00-0000-0000-0000-000000000002")!)
            try store.write(first)
            try store.write(second)

            #expect(Self.jsonFiles(in: directory).count == 2)
            #expect(Set(store.list().map(\.id)) == [first.id, second.id])
        }
    }

    @Test func listSkipsDotFilesAndUndecodableFiles() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let good = Self.session()
            try store.write(good)

            // A temporary file left by a crash in the middle of a write, a truncated file, and garbage.
            let encoded = try JSONEncoder().encode(Self.session())
            try encoded.write(to: directory.appending(path: ".2026-10-12T15-00-00Z-aaaaaa.json.tmp"))
            try Data(encoded.prefix(encoded.count / 2)).write(to: directory.appending(path: "2026-10-12T15-00-00Z-bbbbbb.json"))
            try Data("{ not json".utf8).write(to: directory.appending(path: "corrupt.json"))
            try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))

            #expect(store.list().map(\.id) == [good.id])
        }
    }

    @Test func missingFolderListsNothing() {
        withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory.appending(path: "absent", directoryHint: .isDirectory))
            #expect(store.list().isEmpty)
        }
    }

    @Test func staleRunningSessionFromAnotherLaunchBecomesInterrupted() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let now = Self.start.addingTimeInterval(3_600)
            let currentLaunch = UUID()

            var orphan = Self.session(launchID: UUID(), status: .running)
            orphan.updatedAt = now.addingTimeInterval(-600)
            try store.write(orphan)

            var sameLaunch = Self.session(launchID: currentLaunch, status: .running)
            sameLaunch.updatedAt = now.addingTimeInterval(-600)
            try store.write(sameLaunch)

            var freshOtherMac = Self.session(launchID: UUID(), status: .running)
            freshOtherMac.updatedAt = now.addingTimeInterval(-30)
            try store.write(freshOtherMac)

            var finished = Self.session(launchID: UUID(), status: .cancelled)
            finished.updatedAt = now.addingTimeInterval(-600)
            try store.write(finished)

            var newerSchema = Self.session(launchID: UUID(), status: .running)
            newerSchema.updatedAt = now.addingTimeInterval(-600)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var object = try JSONSerialization.jsonObject(with: encoder.encode(newerSchema)) as! [String: Any]
            object["schema"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appending(path: "newer.json"))

            let changed = try store.markInterrupted(currentLaunch: currentLaunch, now: now)
            #expect(changed == 1)

            let byID = Dictionary(uniqueKeysWithValues: store.list().map { ($0.id, $0) })
            let stopped = try #require(byID[orphan.id])
            #expect(stopped.result.status == .interrupted)
            #expect(stopped.result.reason == "Uncloud quit or the Mac restarted while exporting")
            #expect(stopped.endedAt == orphan.updatedAt)
            #expect(byID[sameLaunch.id]?.result.status == .running)
            #expect(byID[freshOtherMac.id]?.result.status == .running)
            #expect(byID[finished.id]?.result.status == .cancelled)
            // A file from a newer Uncloud is listed read-only and never rewritten.
            #expect(byID.values.contains { $0.schema == 2 && $0.result.status == .running })
        }
    }

    @Test func pruneDeletesWholeOldestChainsOnly() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let oldChain = UUID()
            let middleChain = UUID()
            let newChain = UUID()

            // Oldest chain: two attempts. Middle: one. Newest: two.
            try store.write(Self.session(startedAt: Self.start, id: oldChain, chainID: oldChain))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(60), chainID: oldChain))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(3_600), id: middleChain, chainID: middleChain))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(7_200), id: newChain, chainID: newChain))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(7_260), chainID: newChain))

            let removed = try store.prune(maxFiles: 3, maxBytes: Int.max)
            #expect(removed == 2)
            let remaining = store.list()
            #expect(remaining.count == 3)
            #expect(!remaining.contains { $0.chainID == oldChain })
        }
    }

    @Test func pruneNeverDeletesTheNewestChainOrARunningOne() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let running = UUID()
            let middleChain = UUID()
            let newChain = UUID()

            // The oldest chain is still running, so it must survive the limit.
            try store.write(Self.session(startedAt: Self.start, id: running, chainID: running, status: .running))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(3_600), chainID: middleChain))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(7_200), chainID: newChain))

            _ = try store.prune(maxFiles: 0, maxBytes: 0)
            let remaining = store.list()
            #expect(remaining.count == 2)
            #expect(remaining.contains { $0.chainID == running })
            #expect(remaining.contains { $0.chainID == newChain })
        }
    }

    @Test func pruneRespectsTheByteLimit() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            try store.write(Self.session(startedAt: Self.start))
            try store.write(Self.session(startedAt: Self.start.addingTimeInterval(3_600)))

            let oneFileBytes = Self.jsonFiles(in: directory).reduce(0) { total, name in
                total + ((try? Data(contentsOf: directory.appending(path: name)).count) ?? 0)
            } / 2
            let removed = try store.prune(maxFiles: 100, maxBytes: oneFileBytes)
            #expect(removed == 1)
            #expect(store.list().count == 1)
            #expect(store.list().first?.startedAt == Self.start.addingTimeInterval(3_600))
        }
    }

    /// Two attempts started within the same second list in start order, and files from earlier builds
    /// (whole seconds) still read.
    @Test func sessionsWithinOneSecondKeepTheirOrderAndOldDatesStillRead() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
            var sessions: [ExportSession] = []
            for offset in [0.5, 0.0, 0.25] {
                let session = ExportSession(
                    trigger: .manual, startedAt: start.addingTimeInterval(offset), appVersion: "0.1.4 (14)",
                    launchID: UUID(), source: .iCloud, layout: .month, writesSidecars: false,
                    selection: ExportSession.SelectionSummary(kind: .everything, count: 1)
                )
                sessions.append(session)
                try store.write(session)
            }
            #expect(store.list().map(\.id) == [sessions[1].id, sessions[2].id, sessions[0].id])

            let file = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).first)
            let url = directory.appending(path: file)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            object["startedAt"] = "2026-10-12T14:03:27Z"
            object["updatedAt"] = "2026-10-12T14:03:27Z"
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            #expect(store.list().count == 3)
        }
    }
}
