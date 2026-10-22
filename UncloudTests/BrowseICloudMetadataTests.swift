import Foundation
import Testing
@testable import Uncloud

/// Browse Backup and iCloud: the catalog's rows give a photo its date and place without reading the file, and the
/// camera is read from the file the first time it's asked for. Nothing here touches iCloud or a real drive.
@Suite("BrowseBackup iCloud metadata")
struct BrowseICloudMetadataTests {
    private static let created = Date(timeIntervalSince1970: 1_720_000_000)
    private static let added = Date(timeIntervalSince1970: 1_730_000_000)

    private func row(_ id: String, created: Date?, added: Date?, lat: Double? = nil, lon: Double? = nil) -> ICloudCatalog.Row {
        ICloudCatalog.Row(
            id: id, master: nil, added: added, created: created, filename: "\(id).HEIC", isVideo: false,
            size: nil, bytes: nil, latitude: lat, longitude: lon, timeZoneOffset: nil,
            rank: 0, rankCount: 0, seenAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Catalog rows

    @Test func catalogRowsGiveTheDateAndPlaceOfTheIDsTheyKnow() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_1.HEIC", in: destination)
            try writeFile("b", to: "2024/07/IMG_2.HEIC", in: destination)
            try ExportManifest.appendRecords([
                (key: "icloud-id:A", paths: ["2024/07/IMG_1.HEIC", "2024/07/IMG_1.MOV"]),
                (key: "icloud-id:B", paths: ["2024/07/IMG_2.HEIC"]),
                (key: "icloud-id:C", paths: ["2024/07/IMG_3.HEIC"]),
            ], in: destination)
            let catalog = try ICloudCatalog.open(account: "acct", directory: destination.appending(path: "catalog"))
            try await catalog.upsert([
                row("A", created: Self.created, added: Self.added, lat: 41.9, lon: 12.5),
                row("B", created: nil, added: Self.added),
            ])

            let metadata = try await BrowseIndexer.iCloudMetadata(in: destination, catalog: catalog)
            // C has no row, so it isn't in the result and the indexer reads it. The movie belongs to A's photo.
            #expect(Set(metadata.keys) == ["2024/07/IMG_1.HEIC", "2024/07/IMG_2.HEIC"])
            #expect(metadata["2024/07/IMG_1.HEIC"] == BrowseMetadata(latitude: 41.9, longitude: 12.5, date: Self.created, camera: nil))
            // With no creation date, the added date is used, and a row without a place has none.
            #expect(metadata["2024/07/IMG_2.HEIC"] == BrowseMetadata(latitude: nil, longitude: nil, date: Self.added, camera: nil))
        }
    }

    @Test func rowsAreUsedWithoutReadingTheFile() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_1.HEIC", in: destination)
            try writeFile("b", to: "2024/07/IMG_3.HEIC", in: destination)
            try ExportManifest.appendRecords([
                (key: "icloud-id:A", paths: ["2024/07/IMG_1.HEIC"]),
                (key: "icloud-id:C", paths: ["2024/07/IMG_3.HEIC"]),
            ], in: destination)
            let iCloud = ["2024/07/IMG_1.HEIC": BrowseMetadata(latitude: 41.9, longitude: 12.5, date: Self.created, camera: nil)]
            let reads = ReadCounter()
            let entries = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in reads.record(); return BrowseMetadata(latitude: 1, longitude: 2, date: Self.added) },
                iCloudMetadata: iCloud,
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            // Only the file without a row is read.
            #expect(reads.count == 1)
            let fromRow = try #require(entries["2024/07/IMG_1.HEIC"])
            #expect(fromRow.source == .iCloud)
            #expect(fromRow.date == Self.created)
            #expect(fromRow.latitude == 41.9)
            #expect(fromRow.camera == nil)
            let read = try #require(entries["2024/07/IMG_3.HEIC"])
            #expect(read.source == nil)
            #expect(read.latitude == 1)
        }
    }

    @Test func rowWithoutADateIsReadFromTheFile() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_1.HEIC", in: destination)
            try ExportManifest.appendRecords([(key: "icloud-id:A", paths: ["2024/07/IMG_1.HEIC"])], in: destination)
            let iCloud = ["2024/07/IMG_1.HEIC": BrowseMetadata(latitude: 5, longitude: 6, date: nil, camera: nil)]
            let reads = ReadCounter()
            let entries = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in reads.record(); return BrowseMetadata(date: Self.added) },
                iCloudMetadata: iCloud,
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 1)
            #expect(entries["2024/07/IMG_1.HEIC"]?.source == nil)
            #expect(entries["2024/07/IMG_1.HEIC"]?.date == Self.added)
        }
    }

    @Test func changedFileWithARowIsIndexedFromTheRow() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let photo = try writeFile("a", to: "2024/07/IMG_1.HEIC", in: destination)
            try ExportManifest.appendRecords([(key: "icloud-id:A", paths: ["2024/07/IMG_1.HEIC"])], in: destination)
            let reads = ReadCounter()
            let first = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in reads.record(); return BrowseMetadata(latitude: 1, longitude: 2) },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 1)

            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: photo.path(percentEncoded: false)
            )
            let iCloud = ["2024/07/IMG_1.HEIC": BrowseMetadata(latitude: 41.9, longitude: 12.5, date: Self.created)]
            let second = try await BrowseIndexer.update(
                destination: destination, previous: first,
                read: { _ in reads.record(); return BrowseMetadata() },
                iCloudMetadata: iCloud,
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 1)
            #expect(second["2024/07/IMG_1.HEIC"]?.latitude == 41.9)
            #expect(second["2024/07/IMG_1.HEIC"]?.source == .iCloud)
        }
    }

    @Test func indexFromBeforeTheSourceFieldStillLoads() throws {
        try withTemporaryDirectory { root in
            let json = #"{"version":1,"entries":{"2024/07/a.jpg":{"path":"2024/07/a.jpg","size":3,"modified":1.5,"latitude":1,"longitude":2}}}"#
            try Data(json.utf8).write(to: root.appending(path: "old.json"))
            let entries = BrowseIndexStore(directory: root).load(key: "old")
            let entry = try #require(entries["2024/07/a.jpg"])
            #expect(entry.source == nil)
            #expect(entry.latitude == 1)
        }
    }

    @MainActor
    @Test func indexingBuildsFromTheCatalogProvidedByTheModel() async throws {
        try await withTemporaryDirectoryAsync { root in
            let drive = root.appending(path: "Drive", directoryHint: .isDirectory)
            try writeFile("a", to: "2024/07/IMG_1.HEIC", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:A", paths: ["2024/07/IMG_1.HEIC"])], in: drive)
            let catalog = try ICloudCatalog.open(account: "acct", directory: root.appending(path: "catalog"))
            try await catalog.upsert([row("A", created: Self.created, added: nil, lat: 41.9, lon: 12.5)])

            let browse = BrowseBackup(
                store: BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory)),
                namer: FakeNamer(answers: [:]), isExportRunning: { false },
                iCloudCatalog: { _ in catalog }
            )
            browse.update(destination: drive, name: "Drive", isConnected: true)
            for _ in 0..<200 where browse.isIndexing {
                try await Task.sleep(for: .milliseconds(25))
            }
            let entry = try #require(browse.entries["2024/07/IMG_1.HEIC"])
            #expect(entry.source == .iCloud)
            #expect(entry.date == Self.created)
            #expect(browse.locatedCount == 1)
        }
    }
}
