import CryptoKit
import Foundation
import Testing
@testable import Uncloud

@Suite("Takeout importer")
struct TakeoutImporterTests {
    /// 2019-07-15 12:00 UTC: the month is July in every time zone.
    private static let takenSeconds = 1_563_192_000
    private static let takenDate = Date(timeIntervalSince1970: TimeInterval(takenSeconds))

    /// What an import reported, in order.
    struct Tally {
        var total = -1
        var alreadyExported = -1
        var exported: [String] = []
        var skipped = 0
        var failed: [String] = []
        var notes: [String] = []
    }

    private func sidecar(title: String, taken: Int? = takenSeconds, latitude: Double? = nil, longitude: Double? = nil) -> String {
        var fields = ["\"title\": \"\(title)\""]
        if let taken {
            fields.append("\"photoTakenTime\": {\"timestamp\": \"\(taken)\"}")
        }
        if let latitude, let longitude {
            fields.append("\"geoData\": {\"latitude\": \(latitude), \"longitude\": \(longitude), \"altitude\": 12.0}")
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    private func member(_ path: String, _ text: String, crcOverride: UInt32? = nil) -> ZipTestArchive.Member {
        ZipTestArchive.member(path: path, payload: Data(text.utf8), crcOverride: crcOverride)
    }

    private func writeZip(_ members: [ZipTestArchive.Member], named name: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: name)
        try ZipTestArchive.archive(members).write(to: url)
        return url
    }

    private func importer(_ inputs: [URL], _ layout: FolderLayout, into destination: URL) -> TakeoutImporter {
        TakeoutImporter(destination: destination, layout: layout, inputs: inputs, gate: PauseGate())
    }

    private func run(_ importer: TakeoutImporter) async throws -> Tally {
        var tally = Tally()
        let run = importer.start()
        for try await event in run.events {
            switch event {
            case let .prepared(total, alreadyExported):
                tally.total = total
                tally.alreadyExported = alreadyExported
            case let .exported(name, _, _):
                tally.exported.append(name)
            case .skipped:
                tally.skipped += 1
            case let .failed(name, _):
                tally.failed.append(name)
            case let .note(text):
                tally.notes.append(text)
            default:
                break
            }
        }
        return tally
    }

    private func exists(_ relativePath: String, in destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.appending(path: relativePath).path(percentEncoded: false))
    }

    private func stagingIsEmpty(_ destination: URL) -> Bool {
        let staging = TakeoutImporter.stagingURL(in: destination)
        return ((try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []).isEmpty
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func folderInputMonthLayoutWritesMediaSidecarAndRecords() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("photo one", to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg", in: root)
            try writeFile(
                sidecar(title: "IMG_1.jpg", latitude: 41.9028, longitude: 12.4964),
                to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg.json", in: root
            )
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([root.appending(path: "Takeout")], .month, into: destination))

            #expect(tally.total == 1)
            #expect(tally.alreadyExported == 0)
            #expect(tally.exported == ["IMG_1.jpg"])
            #expect(tally.skipped == 0)
            #expect(tally.failed.isEmpty)
            #expect(exists("2019/07/IMG_1.jpg", in: destination))
            #expect(exists("2019/07/IMG_1.xmp", in: destination))

            let media = destination.appending(path: "2019/07/IMG_1.jpg")
            let sha = try FileHasher.sha256(of: media)
            let records = ExportManifest.records(in: destination)
            #expect(records["google:" + sha] == ["2019/07/IMG_1.jpg", "2019/07/IMG_1.xmp"])
            let checksums = ExportManifest.checksums(in: destination)
            #expect(checksums["2019/07/IMG_1.jpg"] == sha)
            let xmpSHA = try FileHasher.sha256(of: destination.appending(path: "2019/07/IMG_1.xmp"))
            #expect(checksums["2019/07/IMG_1.xmp"] == xmpSHA)

            let modified = try #require(FileManager.default.attributesOfItem(atPath: media.path(percentEncoded: false))[.modificationDate] as? Date)
            #expect(abs(modified.timeIntervalSince(Self.takenDate)) < 1)
            #expect(!ExportManifest.hasIncompleteRun(in: destination))
            #expect(stagingIsEmpty(destination))
        }
    }

    @Test func xmpWrittenByTheImportIsReadBackByBrowseMetadata() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("photo one", to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg", in: root)
            try writeFile(
                sidecar(title: "IMG_1.jpg", latitude: 41.9028, longitude: 12.4964),
                to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg.json", in: root
            )
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)
            _ = try await run(importer([root.appending(path: "Takeout")], .month, into: destination))

            let read = await BrowseMetadata.read(of: destination.appending(path: "2019/07/IMG_1.jpg"))

            #expect(read.date == Self.takenDate)
            let latitude = try #require(read.latitude)
            let longitude = try #require(read.longitude)
            #expect(abs(latitude - 41.9028) < 0.0001)
            #expect(abs(longitude - 12.4964) < 0.0001)
        }
    }

    @Test func zipInputFlatLayoutPlacesFilesAtTheTop() async throws {
        try await withTemporaryDirectoryAsync { root in
            let zip = try writeZip([
                member("Takeout/Google Photos/Photos from 2019/IMG_2.HEIC", "heic bytes"),
                member("Takeout/Google Photos/Photos from 2019/IMG_2.HEIC.json", sidecar(title: "IMG_2.HEIC")),
            ], named: "takeout-001.zip", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([zip], .flat, into: destination))

            #expect(tally.exported == ["IMG_2.HEIC"])
            #expect(exists("IMG_2.HEIC", in: destination))
            #expect(exists("IMG_2.xmp", in: destination))
            let sha = sha256Hex(Data("heic bytes".utf8))
            #expect(ExportManifest.records(in: destination)["google:" + sha] == ["IMG_2.HEIC", "IMG_2.xmp"])
            #expect(stagingIsEmpty(destination))
        }
    }

    @Test func albumLayoutFilesAlbumItemsByAlbumAndTheRestNotInAnAlbum() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("{\"title\": \"Rome 2024\"}", to: "Google Photos/Rome 2024/metadata.json", in: root)
            try writeFile("album photo", to: "Google Photos/Rome 2024/IMG_3.jpg", in: root)
            try writeFile(sidecar(title: "IMG_3.jpg"), to: "Google Photos/Rome 2024/IMG_3.jpg.json", in: root)
            try writeFile("year photo", to: "Google Photos/Photos from 2019/IMG_4.jpg", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([root.appending(path: "Google Photos")], .album, into: destination))

            #expect(tally.total == 2)
            #expect(Set(tally.exported) == ["IMG_3.jpg", "IMG_4.jpg"])
            #expect(exists("Rome 2024/IMG_3.jpg", in: destination))
            #expect(exists("Rome 2024/IMG_3.xmp", in: destination))
            #expect(exists("Not in an Album/IMG_4.jpg", in: destination))
            #expect(!exists("Not in an Album/IMG_4.xmp", in: destination))
            let xmp = try String(contentsOf: destination.appending(path: "Rome 2024/IMG_3.xmp"), encoding: .utf8)
            #expect(xmp.contains("Albums|Rome 2024"))
        }
    }

    @Test func placeLayoutWithoutAResolverUsesUnknownLocation() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("photo one", to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg", in: root)
            try writeFile(sidecar(title: "IMG_1.jpg", latitude: 41.9, longitude: 12.5), to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg.json", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            _ = try await run(importer([root.appending(path: "Takeout")], .placeThenMonth, into: destination))

            #expect(exists("Unknown Location/2019-07/IMG_1.jpg", in: destination))
        }
    }

    @Test func samePhotoInAnAlbumAndAYearIsImportedOnceWithItsAlbum() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("{\"title\": \"Rome\"}", to: "Google Photos/Rome/metadata.json", in: root)
            try writeFile("same bytes", to: "Google Photos/Photos from 2019/IMG_5.jpg", in: root)
            try writeFile(sidecar(title: "IMG_5.jpg"), to: "Google Photos/Photos from 2019/IMG_5.jpg.json", in: root)
            try writeFile("same bytes", to: "Google Photos/Rome/IMG_5.jpg", in: root)
            try writeFile(sidecar(title: "IMG_5.jpg"), to: "Google Photos/Rome/IMG_5.jpg.json", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([root.appending(path: "Google Photos")], .album, into: destination))

            #expect(tally.total == 2)
            #expect(tally.exported == ["IMG_5.jpg"])
            #expect(tally.skipped == 1)
            #expect(exists("Rome/IMG_5.jpg", in: destination))
            #expect(!exists("Not in an Album/IMG_5.jpg", in: destination))
            let files = ExportManifest.records(in: destination).values.flatMap { $0 }.filter { $0.hasSuffix(".jpg") }
            #expect(files == ["Rome/IMG_5.jpg"])
        }
    }

    @Test func sidecarInAnotherZipPartDatesThePhoto() async throws {
        try await withTemporaryDirectoryAsync { root in
            let photoPart = try writeZip([member("Takeout/Google Photos/Photos from 2019/IMG_6.jpg", "part one photo")],
                                         named: "takeout-001.zip", in: root)
            let sidecarPart = try writeZip([
                member("Takeout/Google Photos/Photos from 2019/IMG_6.jpg.json", sidecar(title: "IMG_6.jpg")),
            ], named: "takeout-002.zip", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([photoPart, sidecarPart], .month, into: destination))

            #expect(tally.exported == ["IMG_6.jpg"])
            #expect(exists("2019/07/IMG_6.xmp", in: destination))
            let media = destination.appending(path: "2019/07/IMG_6.jpg")
            let modified = try #require(FileManager.default.attributesOfItem(atPath: media.path(percentEncoded: false))[.modificationDate] as? Date)
            #expect(abs(modified.timeIntervalSince(Self.takenDate)) < 1)
        }
    }

    @Test func truncatedSidecarStillImportsThePhoto() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("photo six", to: "Takeout/Google Photos/Photos from 2019/IMG_6.jpg", in: root)
            try writeFile("{\"title\": \"IMG_6.jpg\", \"photoTaken", to: "Takeout/Google Photos/Photos from 2019/IMG_6.jpg.json", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([root.appending(path: "Takeout")], .flat, into: destination))

            #expect(tally.exported == ["IMG_6.jpg"])
            #expect(exists("IMG_6.jpg", in: destination))
            #expect(!exists("IMG_6.xmp", in: destination))
            #expect(ExportManifest.records(in: destination)["google:" + sha256Hex(Data("photo six".utf8))] == ["IMG_6.jpg"])
        }
    }

    @Test func livePhotoPairImportsBothFiles() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("still", to: "Takeout/Google Photos/Photos from 2019/IMG_7.HEIC", in: root)
            try writeFile("movie", to: "Takeout/Google Photos/Photos from 2019/IMG_7.MP4", in: root)
            try writeFile(sidecar(title: "IMG_7.HEIC"), to: "Takeout/Google Photos/Photos from 2019/IMG_7.HEIC.json", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([root.appending(path: "Takeout")], .month, into: destination))

            #expect(tally.exported == ["IMG_7.HEIC", "IMG_7.MP4"])
            #expect(exists("2019/07/IMG_7.HEIC", in: destination))
            #expect(exists("2019/07/IMG_7.MP4", in: destination))
            #expect(exists("2019/07/IMG_7.xmp", in: destination))
            #expect(exists("2019/07/IMG_7.MP4.xmp", in: destination))
        }
    }

    @Test func fileWhoseChecksumIsAlreadyInTheBackupIsSkipped() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("photo one", to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg", in: root)
            try writeFile(sidecar(title: "IMG_1.jpg"), to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg.json", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordChecksums(["2019/07/Earlier export.jpg": sha256Hex(Data("photo one".utf8))])

            let tally = try await run(importer([root.appending(path: "Takeout")], .month, into: destination))

            #expect(tally.exported.isEmpty)
            #expect(tally.skipped == 1)
            #expect(!exists("2019/07/IMG_1.jpg", in: destination))
            #expect(stagingIsEmpty(destination))
        }
    }

    @Test func resumeViaJournalImportsNothingAgain() async throws {
        try await withTemporaryDirectoryAsync { root in
            try writeFile("photo one", to: "Takeout/Google Photos/Photos from 2019/IMG_1.jpg", in: root)
            try writeFile("photo two", to: "Takeout/Google Photos/Photos from 2019/IMG_2.jpg", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)
            let job = importer([root.appending(path: "Takeout")], .flat, into: destination)

            let first = try await run(job)
            let second = try await run(job)

            #expect(first.exported.count == 2)
            #expect(second.total == 2)
            #expect(second.alreadyExported == 2)
            #expect(second.exported.isEmpty)
            #expect(second.skipped == 0)
            #expect(second.failed.isEmpty)
            #expect(TakeoutImportJournal.parse(in: destination).count == 2)
        }
    }

    @Test func corruptZipEntryFailsAndTheRunContinues() async throws {
        try await withTemporaryDirectoryAsync { root in
            let zip = try writeZip([
                member("Takeout/Google Photos/Photos from 2019/IMG_10.jpg", "damaged bytes", crcOverride: 0x1234_5678),
                member("Takeout/Google Photos/Photos from 2019/IMG_11.jpg", "good bytes"),
            ], named: "takeout-001.zip", in: root)
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([zip], .flat, into: destination))

            #expect(tally.failed == ["IMG_10.jpg"])
            #expect(tally.exported == ["IMG_11.jpg"])
            #expect(!exists("IMG_10.jpg", in: destination))
            #expect(exists("IMG_11.jpg", in: destination))
            #expect(stagingIsEmpty(destination))
        }
    }

    @Test func unreadableInputIsNotedAndNothingIsImported() async throws {
        try await withTemporaryDirectoryAsync { root in
            let destination = root.appending(path: "Backup", directoryHint: .isDirectory)

            let tally = try await run(importer([root.appending(path: "Missing Folder")], .month, into: destination))

            #expect(tally.total == 0)
            #expect(tally.exported.isEmpty)
            #expect(tally.notes.contains { $0.contains("Missing Folder") })
        }
    }

    @Test func journalIgnoresAHalfWrittenLastLineAndAppendsAfterIt() throws {
        try withTemporaryDirectory { destination in
            let url = TakeoutImportJournal.url(in: destination)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let done = String(repeating: "a", count: 64)
            try Data("a|1|5\t\(done)\nb|2|5\tpartial".utf8).write(to: url)

            let journal = try TakeoutImportJournal(destination: destination)

            #expect(journal.contains("a|1|5"))
            #expect(!journal.contains("b|2|5"))
            #expect(journal.count == 1)
            try journal.record(sourceKey: "c|3|5", sha256: "abc")
            #expect(TakeoutImportJournal.parse(in: destination) == ["a|1|5": done, "c|3|5": "abc"])
        }
    }
}

/// Section 5: the readers that count, list or plan from manifest records must treat `google:` records as they should.
@Suite("Google records in other manifest readers")
struct GoogleRecordReaderTests {
    private static let google = ExportManifest.googleKeyPrefix + String(repeating: "a", count: 64)

    private func seededDestination(_ root: URL) throws -> URL {
        let destination = root.appending(path: "Backup", directoryHint: .isDirectory)
        try ExportManifest.appendRecords([
            (key: Self.google, paths: ["2019/07/IMG_1.jpg", "2019/07/IMG_1.xmp"]),
            (key: "icloud-id:ASSET-1", paths: ["2019/07/IMG_2.jpg"]),
        ], in: destination)
        return destination
    }

    @Test func iCloudCountsAndListsIgnoreGoogleRecords() throws {
        try withTemporaryDirectory { root in
            let destination = try seededDestination(root)
            let records = ExportManifest.records(in: destination)

            #expect(records[Self.google] == ["2019/07/IMG_1.jpg", "2019/07/IMG_1.xmp"])
            #expect(ExportManifest.iCloudItems(in: destination).keys.sorted() == ["ASSET-1"])
            let count = ICloudItemCount.count(records: records)
            #expect(count.exact == 1)
            #expect(count.total == 1)
            #expect(ICloudItemCount.itemsByLayout(records: records) == [.month: 1])
            #expect(ICloudItemCount.count(records: records, layout: .month).total == 1)
        }
    }

    @Test func photosLibraryCountIgnoresGoogleRecords() {
        let records: [String: [String]] = [
            "ABC/L0/001": ["2019/07/IMG_2.jpg"],
            Self.google: ["2019/07/IMG_1.jpg"],
        ]

        let counted = DriveCheck.onDrive(
            records: records, source: .photosLibrary, selection: .everything, selectedCount: 0, libraryIDs: nil
        )

        #expect(counted.count == 1)
    }

    @Test func reorganizePlannerLeavesGoogleFilesInPlace() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let input = ReorganizePlanner.Input(
            records: [
                Self.google: ["IMG_1.jpg"],
                "icloud-id:ASSET-1": ["IMG_2.jpg"],
            ],
            rootListing: [
                "IMG_1.jpg": .init(size: 10, modified: 1_563_192_000),
                "IMG_2.jpg": .init(size: 11, modified: 1_563_192_000),
            ],
            targetListings: [:],
            createdByKey: ["icloud-id:ASSET-1": Date(timeIntervalSince1970: 1_563_192_000)],
            calendar: calendar
        )

        let plan = ReorganizePlanner.plan(input)

        #expect(plan.moves.map(\.old) == ["IMG_2.jpg"])
        #expect(plan.moves.allSatisfy { !$0.key.hasPrefix(ExportManifest.googleKeyPrefix) })
        #expect(plan.staying == 0)
    }

    @Test func browseIndexIncludesGoogleMedia() throws {
        try withTemporaryDirectory { root in
            let destination = try seededDestination(root)

            let paths = BrowseIndexer.mediaPaths(in: destination)

            #expect(paths == ["2019/07/IMG_1.jpg", "2019/07/IMG_2.jpg"])
        }
    }

    @Test func flatFolderCheckCountsGoogleFilesAsRecorded() throws {
        try withTemporaryDirectory { destination in
            try ExportManifest.appendRecords([(key: Self.google, paths: ["IMG_1.jpg"])], in: destination)
            try writeFile("photo", to: "IMG_1.jpg", in: destination)
            try writeFile("notes", to: "notes.txt", in: destination)

            let count = FlatFolderCheck.unrecordedEntryCount(in: destination, records: ExportManifest.records(in: destination))

            #expect(count == 1)
        }
    }
}
