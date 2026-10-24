import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Uncloud

/// Browse Backup: the metadata readers, the index, the places and the model's rules. Fixture images are written with
/// ImageIO, with GPS dictionaries, into temporary folders. Nothing here touches iCloud, the Photos library or a real drive.
@Suite("BrowseBackup")
struct BrowseBackupTests {
    // MARK: - GPS from photos

    @Test func readsSignedGPSFromJPEG() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let url = folder.appending(path: "north-east.jpg")
            try writeImage(at: url, type: UTType.jpeg.identifier, gps: gps(latitude: 41.9028, longitude: 12.4964))
            let metadata = await BrowseMetadata.read(of: url)
            let metadataLatitude = try #require(metadata.latitude)
            #expect(abs(metadataLatitude - 41.9028) < 1e-6)
            let metadataLongitude = try #require(metadata.longitude)
            #expect(abs(metadataLongitude - 12.4964) < 1e-6)
        }
    }

    @Test func readsSouthAndWestAsNegative() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let url = folder.appending(path: "south-west.png")
            try writeImage(at: url, type: UTType.png.identifier, gps: gps(latitude: -33.8688, longitude: -151.2093))
            let metadata = await BrowseMetadata.read(of: url)
            let metadataLatitude = try #require(metadata.latitude)
            #expect(abs(metadataLatitude + 33.8688) < 1e-6)
            let metadataLongitude = try #require(metadata.longitude)
            #expect(abs(metadataLongitude + 151.2093) < 1e-6)
        }
    }

    @Test func readsEveryHemisphereCombination() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let cases: [(Double, Double, String, String)] = [
                (10, 20, "N", "E"), (-10, 20, "S", "E"), (10, -20, "N", "W"), (-10, -20, "S", "W"),
            ]
            for (index, item) in cases.enumerated() {
                let url = folder.appending(path: "case-\(index).jpg")
                var dictionary: [CFString: Any] = [:]
                dictionary[kCGImagePropertyGPSLatitude] = abs(item.0)
                dictionary[kCGImagePropertyGPSLatitudeRef] = item.2
                dictionary[kCGImagePropertyGPSLongitude] = abs(item.1)
                dictionary[kCGImagePropertyGPSLongitudeRef] = item.3
                try writeImage(at: url, type: UTType.jpeg.identifier, gps: dictionary)
                let metadata = await BrowseMetadata.read(of: url)
                #expect(metadata.latitude == item.0)
                #expect(metadata.longitude == item.1)
            }
        }
    }

    @Test func readsGPSFromHEICWhenEncoderIsAvailable() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let url = folder.appending(path: "IMG_0001.HEIC")
            // Some Macs can't encode HEIC; then there's nothing to test, and PNG and JPEG cover the reader.
            guard (try? writeImage(at: url, type: UTType.heic.identifier, gps: gps(latitude: 48.8566, longitude: 2.3522))) != nil else {
                return
            }
            let metadata = await BrowseMetadata.read(of: url)
            let metadataLatitude = try #require(metadata.latitude)
            #expect(abs(metadataLatitude - 48.8566) < 1e-6)
            let metadataLongitude = try #require(metadata.longitude)
            #expect(abs(metadataLongitude - 2.3522) < 1e-6)
        }
    }

    @Test func readsDateAndCameraFromEXIF() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let url = folder.appending(path: "shot.jpg")
            try writeImage(at: url, type: UTType.jpeg.identifier, dateTimeOriginal: "2024:07:04 18:30:00", make: "Apple", model: "iPhone 15")
            let metadata = await BrowseMetadata.read(of: url)
            #expect(metadata.camera == "Apple iPhone 15")
            #expect(metadata.date != nil)
            #expect(metadata.hasLocation == false)
        }
    }

    @Test func photoWithoutGPSHasNoLocation() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let url = folder.appending(path: "plain.png")
            try writeImage(at: url, type: UTType.png.identifier)
            let metadata = await BrowseMetadata.read(of: url)
            #expect(metadata.hasLocation == false)
        }
    }

    // MARK: - Parsers

    @Test func parsesISO6709MovieLocation() {
        let northEast = BrowseMetadata.parseISO6709("+41.9028+012.4964+050.000/")
        #expect(northEast?.latitude == 41.9028)
        #expect(northEast?.longitude == 12.4964)

        let southWest = BrowseMetadata.parseISO6709("-33.8688-151.2093/")
        #expect(southWest?.latitude == -33.8688)
        #expect(southWest?.longitude == -151.2093)

        let withoutAltitude = BrowseMetadata.parseISO6709("+10.5-020.25")
        #expect(withoutAltitude?.latitude == 10.5)
        #expect(withoutAltitude?.longitude == -20.25)
    }

    @Test func rejectsMalformedISO6709() {
        #expect(BrowseMetadata.parseISO6709("41.9028 12.4964") == nil)
        #expect(BrowseMetadata.parseISO6709("+41.9028") == nil)
        #expect(BrowseMetadata.parseISO6709("+95.0+012.0/") == nil)
        #expect(BrowseMetadata.parseISO6709("+10.0+200.0/") == nil)
        #expect(BrowseMetadata.parseISO6709("") == nil)
    }

    @Test func parsesDegreesAndMinutesFromXMP() {
        #expect(abs((BrowseXMP.coordinate("41,53.1234N") ?? 0) - (41 + 53.1234 / 60)) < 1e-9)
        #expect(abs((BrowseXMP.coordinate("33,52.0S") ?? 0) + (33 + 52.0 / 60)) < 1e-9)
        #expect(abs((BrowseXMP.coordinate("151,12.5W") ?? 0) + (151 + 12.5 / 60)) < 1e-9)
        #expect(BrowseXMP.coordinate("nonsense") == nil)
        #expect(BrowseXMP.coordinate("41,99.0N") == nil)
    }

    @Test func xmpFallbackRoundTripsWithXMPSidecarWriter() throws {
        try withTemporaryDirectory { folder in
            let metadata = AssetMetadata(
                localIdentifier: "A",
                creationDate: Date(timeIntervalSince1970: 1_720_000_000),
                modificationDate: nil,
                latitude: -33.86885,
                longitude: 151.20931,
                altitude: nil,
                isFavorite: false,
                isHidden: false,
                albums: []
            )
            let url = folder.appending(path: "IMG_0002.mov")
            try Data().write(to: url)
            try Data(XMPSidecar.xml(for: metadata).utf8).write(to: folder.appending(path: "IMG_0002.xmp"))
            let parsed = try #require(BrowseXMP.parse(try Data(contentsOf: folder.appending(path: "IMG_0002.xmp"))))
            let parsedLatitude = try #require(parsed.latitude)
            #expect(abs(parsedLatitude - -33.86885) < 1e-5)
            let parsedLongitude = try #require(parsed.longitude)
            #expect(abs(parsedLongitude - 151.20931) < 1e-5)
            #expect(parsed.date != nil)
        }
    }

    @Test func xmpWithoutCoordinatesHasNone() throws {
        let metadata = AssetMetadata(
            localIdentifier: "B", creationDate: nil, modificationDate: nil, latitude: nil, longitude: nil,
            altitude: nil, isFavorite: false, isHidden: false, albums: []
        )
        let parsed = try #require(BrowseXMP.parse(Data(XMPSidecar.xml(for: metadata).utf8)))
        #expect(parsed.latitude == nil)
        #expect(parsed.longitude == nil)
    }

    @Test func sidecarFillsInAPhotoWithoutGPS() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let photo = folder.appending(path: "IMG_0003.jpg")
            try writeImage(at: photo, type: UTType.jpeg.identifier)
            let metadata = AssetMetadata(
                localIdentifier: "C", creationDate: nil, modificationDate: nil, latitude: 10.25, longitude: -20.5,
                altitude: nil, isFavorite: false, isHidden: false, albums: []
            )
            try Data(XMPSidecar.xml(for: metadata).utf8).write(to: folder.appending(path: "IMG_0003.xmp"))
            let read = await BrowseMetadata.read(of: photo)
            let readLatitude = try #require(read.latitude)
            #expect(abs(readLatitude - 10.25) < 1e-5)
            let readLongitude = try #require(read.longitude)
            #expect(abs(readLongitude + 20.5) < 1e-5)
        }
    }

    @Test func cameraNameAvoidsRepeatingTheMake() {
        #expect(BrowseMetadata.cameraName(make: "Apple", model: "iPhone 15") == "Apple iPhone 15")
        #expect(BrowseMetadata.cameraName(make: "NIKON", model: "NIKON Z 6") == "NIKON Z 6")
        #expect(BrowseMetadata.cameraName(make: "", model: "") == nil)
    }

    @Test func exifDateUsesTheRecordedOffset() {
        let date = BrowseMetadata.exifDate("2024:07:04 18:30:00", offset: "+02:00")
        let expected = ISO8601DateFormatter().date(from: "2024-07-04T18:30:00+02:00")
        #expect(date == expected)
    }

    // MARK: - Index: which files

    @Test func livePhotoMovieAndSidecarAreExcluded() throws {
        try withTemporaryDirectory { destination in
            try ExportManifest.appendRecords([
                (key: "icloud-id:A", paths: ["2024/07/IMG_1.HEIC", "2024/07/IMG_1.MOV", "2024/07/IMG_1.xmp"]),
                (key: "icloud-id:B", paths: ["2024/07/IMG_2.MOV"]),
                (key: "icloud:2024/07/IMG_3.JPG", paths: ["2024/07/IMG_3.JPG"]),
            ], in: destination)
            let paths = BrowseIndexer.mediaPaths(in: destination)
            // IMG_1's movie belongs to its photo; IMG_2's movie has no recorded photo, so it stays.
            #expect(paths == ["2024/07/IMG_1.HEIC", "2024/07/IMG_2.MOV", "2024/07/IMG_3.JPG"])
        }
    }

    @Test func livePhotoPairingMatchesDriveCheck() {
        let movies = ICloudItemCount.livePhotoMovies(in: ["a/IMG_1.HEIC", "a/IMG_1.MOV", "b/IMG_1.MOV", "a/IMG_2.MOV"])
        #expect(movies == ["a/IMG_1.MOV"])
    }

    @Test func missingFilesAreSkipped() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("x", to: "2024/07/here.jpg", in: destination)
            try ExportManifest.appendRecords([
                (key: "icloud-id:A", paths: ["2024/07/here.jpg"]),
                (key: "icloud-id:B", paths: ["2024/07/gone.jpg"]),
            ], in: destination)
            let entries = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(Set(entries.keys) == ["2024/07/here.jpg"])
        }
    }

    @Test func disconnectedDriveThrowsWithoutDroppingEntries() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "uncloud-browse-missing-\(UUID().uuidString)")
        let previous = ["2024/07/a.jpg": BrowseEntry(path: "2024/07/a.jpg", size: 1, modified: 1, latitude: 1, longitude: 1, date: nil, camera: nil)]
        await #expect(throws: BrowseIndexError.driveUnavailable) {
            _ = try await BrowseIndexer.update(
                destination: missing, previous: previous,
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
        }
    }

    // MARK: - Index: incremental

    @Test func unchangedFileIsNotReadAgain() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let photo = try writeFile("one", to: "2024/07/IMG_1.jpg", in: destination)
            try ExportManifest.appendRecords([(key: "icloud-id:A", paths: ["2024/07/IMG_1.jpg"])], in: destination)
            let reads = ReadCounter()
            let first = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { url in reads.record(); return BrowseMetadata(latitude: 1, longitude: 2) },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 1)

            _ = try await BrowseIndexer.update(
                destination: destination, previous: first,
                read: { url in reads.record(); return BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 1)

            // A new modification time means the file is read again, and its new location is kept.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: photo.path(percentEncoded: false)
            )
            let third = try await BrowseIndexer.update(
                destination: destination, previous: first,
                read: { url in reads.record(); return BrowseMetadata(latitude: 5, longitude: 6) },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 2)
            #expect(third["2024/07/IMG_1.jpg"]?.latitude == 5)
        }
    }

    @Test func indexPersistsEvery1000FilesAndAtTheEnd() async throws {
        try await withTemporaryDirectoryAsync { destination in
            var keys: [String] = []
            for index in 0..<1_050 {
                let path = "2024/07/IMG_\(index).jpg"
                try writeFile("x", to: path, in: destination)
                keys.append(path)
            }
            try ExportManifest.appendRecords(keys.map { (key: "icloud-id:\($0)", paths: [$0]) }, in: destination)
            let saves = SaveCounter()
            _ = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { saves.record($0.count) }
            )
            // One save at 1,000 files, one at the end.
            #expect(saves.counts == [1_000, 1_050])
        }
    }

    @Test func persistWaitsForTheSaveIntervalWhenTheClockStandsStill() async throws {
        try await withTemporaryDirectoryAsync { destination in
            var keys: [String] = []
            for index in 0..<3_000 {
                let path = "2024/07/IMG_\(index).jpg"
                try writeFile("x", to: path, in: destination)
                keys.append(path)
            }
            try ExportManifest.appendRecords(keys.map { (key: "icloud-id:\($0)", paths: [$0]) }, in: destination)
            let saves = SaveCounter()
            let clock = FakeClock(start: 0, step: 0)
            _ = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { saves.record($0.count) },
                clock: { clock.read() }
            )
            // The first 1,000 mark saves. The next marks come less than 30 s later, so they don't. The end always saves.
            #expect(saves.counts == [1_000, 3_000])
        }
    }

    @Test func persistRunsAtEachMarkWhenTheIntervalHasPassed() async throws {
        try await withTemporaryDirectoryAsync { destination in
            var keys: [String] = []
            for index in 0..<3_000 {
                let path = "2024/07/IMG_\(index).jpg"
                try writeFile("x", to: path, in: destination)
                keys.append(path)
            }
            try ExportManifest.appendRecords(keys.map { (key: "icloud-id:\($0)", paths: [$0]) }, in: destination)
            let saves = SaveCounter()
            // Each read of the clock is 40 s later than the last, so every mark is due.
            let clock = FakeClock(start: 0, step: 40)
            _ = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { saves.record($0.count) },
                clock: { clock.read() }
            )
            #expect(saves.counts == [1_000, 2_000, 3_000, 3_000])
        }
    }

    @Test func changedSizeIsReadAgainEvenWhenTheTimeIsTheSame() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("one", to: "2024/07/IMG_2.jpg", in: destination)
            try ExportManifest.appendRecords([(key: "icloud-id:B", paths: ["2024/07/IMG_2.jpg"])], in: destination)
            let reads = ReadCounter()
            var previous = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in reads.record(); return BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 1)
            // The stored size is off, so the listed size differs even though the time matches.
            previous["2024/07/IMG_2.jpg"]?.size = 999

            _ = try await BrowseIndexer.update(
                destination: destination, previous: previous,
                read: { _ in reads.record(); return BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(reads.count == 2)
        }
    }

    @Test func removedFileIsDroppedFromTheIndex() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/kept.jpg", in: destination)
            let removed = try writeFile("b", to: "2024/07/removed.jpg", in: destination)
            try ExportManifest.appendRecords([
                (key: "icloud-id:A", paths: ["2024/07/kept.jpg"]),
                (key: "icloud-id:B", paths: ["2024/07/removed.jpg"]),
            ], in: destination)
            let first = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(Set(first.keys) == ["2024/07/kept.jpg", "2024/07/removed.jpg"])

            try FileManager.default.removeItem(at: removed)
            let second = try await BrowseIndexer.update(
                destination: destination, previous: first,
                read: { _ in BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(Set(second.keys) == ["2024/07/kept.jpg"])
        }
    }

    @Test func xmpSidecarFallbackStillWorksThroughTheListing() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let photo = destination.appending(path: "2024/07/IMG_3.jpg")
            try FileManager.default.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeImage(at: photo, type: UTType.jpeg.identifier)
            let metadata = AssetMetadata(
                localIdentifier: "C", creationDate: nil, modificationDate: nil, latitude: 10.25, longitude: -20.5,
                altitude: nil, isFavorite: false, isHidden: false, albums: []
            )
            try Data(XMPSidecar.xml(for: metadata).utf8).write(to: photo.deletingLastPathComponent().appending(path: "IMG_3.xmp"))
            try ExportManifest.appendRecords([(key: "icloud-id:C", paths: ["2024/07/IMG_3.jpg"])], in: destination)

            // No `read` closure: the indexer's own read, with its sidecar check taken from the listing.
            let entries = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )

            let latitude = try #require(entries["2024/07/IMG_3.jpg"]?.latitude)
            #expect(abs(latitude - 10.25) < 1e-5)
        }
    }

    @Test func entriesStampedByFileManagerAreNotReadAgainAfterTheListingChange() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let photo = try writeFile("one", to: "2024/07/IMG_4.jpg", in: destination)
            // A timestamp whose microseconds round, which is where a naive conversion would differ from FileManager.
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
            #expect(utimensat(AT_FDCWD, photo.path(percentEncoded: false), &times, 0) == 0)
            try ExportManifest.appendRecords([(key: "icloud-id:D", paths: ["2024/07/IMG_4.jpg"])], in: destination)
            // The index as it was written before the listing: each stamp came from FileManager.
            let stamp = try #require(BrowseIndexer.fileStamp(of: photo))
            let previous = ["2024/07/IMG_4.jpg": BrowseEntry(
                path: "2024/07/IMG_4.jpg", size: stamp.size, modified: stamp.modified,
                latitude: 1, longitude: 2, date: nil, camera: nil
            )]
            let reads = ReadCounter()

            let updated = try await BrowseIndexer.update(
                destination: destination, previous: previous,
                read: { _ in reads.record(); return BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )

            #expect(reads.count == 0)
            #expect(updated["2024/07/IMG_4.jpg"]?.latitude == 1)
        }
    }

    @Test func unlistableFolderKeepsItsEntriesWithoutReadingThem() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("one", to: "2024/07/IMG_1.jpg", in: destination)
            try writeFile("two", to: "2024/08/IMG_2.jpg", in: destination)
            try ExportManifest.appendRecords([
                (key: "icloud-id:A", paths: ["2024/07/IMG_1.jpg"]),
                (key: "icloud-id:B", paths: ["2024/08/IMG_2.jpg"]),
            ], in: destination)
            let first = try await BrowseIndexer.update(
                destination: destination, previous: [:],
                read: { _ in BrowseMetadata(latitude: 1, longitude: 2) },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )
            #expect(first.count == 2)

            // EACCES on one folder: its files can't be listed, but they still exist.
            let locked = destination.appending(path: "2024/07", directoryHint: .isDirectory)
            #expect(chmod(locked.path(percentEncoded: false), 0) == 0)
            defer { _ = chmod(locked.path(percentEncoded: false), 0o755) }
            let reads = ReadCounter()

            let second = try await BrowseIndexer.update(
                destination: destination, previous: first,
                read: { _ in reads.record(); return BrowseMetadata() },
                waitWhilePaused: {}, progress: { _, _ in }, persist: { _ in }
            )

            #expect(second["2024/07/IMG_1.jpg"] == first["2024/07/IMG_1.jpg"], "the locked folder's entry is kept")
            #expect(second["2024/08/IMG_2.jpg"] == first["2024/08/IMG_2.jpg"])
            #expect(reads.count == 0)
        }
    }

    @Test func destinationKeyIsStableAndPerFolder() {
        withTemporaryDirectory { root in
            let one = root.appending(path: "One", directoryHint: .isDirectory)
            let two = root.appending(path: "Two", directoryHint: .isDirectory)
            #expect(NewPhotosContext.destinationKey(for: one) == NewPhotosContext.destinationKey(for: one))
            #expect(NewPhotosContext.destinationKey(for: one) != NewPhotosContext.destinationKey(for: two))
        }
    }

    // MARK: - Places

    @Test func groupsCellsByPlaceWithFakeResolver() async throws {
        let entries = [
            located("2024/07/a.jpg", 41.9028, 12.4964),
            located("2024/07/b.jpg", 41.9031, 12.4970),
            located("2024/08/c.jpg", -33.8688, 151.2093),
            located("2024/08/d.jpg", 41.9040, 12.4950),
        ]
        let cells = BrowsePlaces.cells(from: entries)
        #expect(cells.count == 2)
        let namer = FakeNamer(answers: [
            PlaceResolver.cellKey(latitude: 41.9028, longitude: 12.4964): PlaceResolver.Place(country: "Italy", city: "Rome"),
            PlaceResolver.cellKey(latitude: -33.8688, longitude: 151.2093): PlaceResolver.Place(country: "Australia", city: "Sydney"),
        ])
        let result = await BrowsePlaces.resolveNames(for: cells, known: [:], using: namer)
        #expect(result.failed.isEmpty)
        let groups = BrowsePlaces.groups(cells: cells, names: result.named, noLocation: [])
        #expect(groups.map(\.title) == ["Italy › Rome", "Australia › Sydney"])
        #expect(groups.map(\.count) == [3, 1])
        #expect(groups.allSatisfy { $0.isNamed })
    }

    @Test func offlineCellsShowCoordinatesAndFailedLookupsAreReported() async throws {
        let cells = BrowsePlaces.cells(from: [located("2024/07/a.jpg", 41.9028, 12.4964)])
        let result = await BrowsePlaces.resolveNames(for: cells, known: [:], using: FakeNamer(answers: [:], offline: true))
        #expect(result.named.isEmpty)
        #expect(result.failed == Set(cells.map(\.key)))
        let groups = BrowsePlaces.groups(cells: cells, names: [:], noLocation: [])
        #expect(groups.count == 1)
        #expect(groups[0].isNamed == false)
        #expect(groups[0].title == "41.90, 12.50")
    }

    @Test func notFoundCoordinatesAreUnknownPlace() {
        #expect(BrowsePlaces.title(for: PlaceResolver.Place()) == "Unknown Place")
        #expect(BrowsePlaces.title(for: PlaceResolver.Place(country: "Italy", city: nil)) == "Italy")
    }

    @Test func photosWithoutGPSGoToNoLocation() {
        let entries = [
            located("2024/07/a.jpg", 41.9, 12.5),
            BrowseEntry(path: "2024/07/b.jpg", size: 1, modified: 1, latitude: nil, longitude: nil, date: nil, camera: nil),
            BrowseEntry(path: "2024/07/c.jpg", size: 1, modified: 1, latitude: nil, longitude: nil, date: nil, camera: nil),
        ]
        let groups = BrowsePlaces.groups(
            cells: BrowsePlaces.cells(from: entries), names: [:],
            noLocation: entries.filter { !$0.hasLocation }.map(\.path)
        )
        let last = try? #require(groups.last)
        #expect(last?.isNoLocation == true)
        #expect(last?.title == "No Location")
        #expect(last?.count == 2)
    }

    // MARK: - Model

    @MainActor
    @Test func searchFiltersPlacesByName() throws {
        try withTemporaryDirectory { root in
            let browse = BrowseBackup(store: BrowseIndexStore(directory: root), namer: FakeNamer(answers: [:]), isExportRunning: { false })
            let entries = [
                located("2024/07/a.jpg", 41.9028, 12.4964),
                located("2024/08/b.jpg", -33.8688, 151.2093),
            ]
            let rome = PlaceResolver.cellKey(latitude: 41.9028, longitude: 12.4964)
            let sydney = PlaceResolver.cellKey(latitude: -33.8688, longitude: 151.2093)
            browse.load(
                entries: entries,
                names: [rome: PlaceResolver.Place(country: "Italy", city: "Rome"), sydney: PlaceResolver.Place(country: "Australia", city: "Sydney")],
                destination: root
            )
            #expect(browse.visibleGroups.count == 2)
            browse.query = "syd"
            #expect(browse.visibleGroups.map(\.title) == ["Australia › Sydney"])
            #expect(browse.visibleCells.map(\.key) == [sydney])
        }
    }

    @MainActor
    @Test func indexingFillsThePlacesFromTheDrive() async throws {
        try await withTemporaryDirectoryAsync { root in
            let drive = root.appending(path: "Drive", directoryHint: .isDirectory)
            let store = BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            try writeImage(at: drive.appending(path: "2024/07/IMG_1.jpg"), type: UTType.jpeg.identifier, gps: gps(latitude: 41.9028, longitude: 12.4964))
            try writeImage(at: drive.appending(path: "2024/07/IMG_2.jpg"), type: UTType.jpeg.identifier)
            try ExportManifest.appendRecords([
                (key: "icloud-id:1", paths: ["2024/07/IMG_1.jpg"]),
                (key: "icloud-id:2", paths: ["2024/07/IMG_2.jpg"]),
            ], in: drive)

            let browse = BrowseBackup(store: store, namer: FakeNamer(answers: [
                PlaceResolver.cellKey(latitude: 41.9028, longitude: 12.4964): PlaceResolver.Place(country: "Italy", city: "Rome"),
            ]), isExportRunning: { false })
            browse.update(destination: drive, name: "Drive", isConnected: true)
            for _ in 0..<200 where browse.isIndexing {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(browse.isIndexing == false)
            #expect(browse.entries.count == 2)
            #expect(browse.locatedCount == 1)
            #expect(browse.noLocationPaths == ["2024/07/IMG_2.jpg"])

            browse.requestNames(for: Set(browse.cells.map(\.key)))
            for _ in 0..<200 where browse.names.isEmpty {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(browse.groups.first?.title == "Italy › Rome")

            // The index was saved, so a new model reads it without the drive being indexed again.
            let reopened = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false })
            reopened.update(destination: drive, name: "Drive", isConnected: false)
            #expect(reopened.entries.count == 2)
        }
    }

    // MARK: - Index: after an export

    @Test @MainActor func indexStartedDuringAnExportListsFilesWrittenBeforeTheExportEnds() async throws {
        try await withTemporaryDirectoryAsync { root in
            let drive = root.appending(path: "Drive", directoryHint: .isDirectory)
            let store = BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            try writeFile("a", to: "2024/07/IMG_1.jpg", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:1", paths: ["2024/07/IMG_1.jpg"])], in: drive)

            let export = ExportStub(isRunning: true)
            let browse = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { export.check() })
            browse.update(destination: drive, name: "Drive", isConnected: true)
            for _ in 0..<200 where !browse.isPaused {
                try await Task.sleep(for: .milliseconds(25))
            }

            // The export writes its file while the index waits, then ends.
            try writeFile("b", to: "2024/07/IMG_2.jpg", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:2", paths: ["2024/07/IMG_2.jpg"])], in: drive)
            export.isRunning = false
            for _ in 0..<200 where browse.isIndexing {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(Set(browse.entries.keys) == ["2024/07/IMG_1.jpg", "2024/07/IMG_2.jpg"])
        }
    }

    @Test @MainActor func refreshDuringAnIndexRunsOneMorePassThatPicksUpANewFile() async throws {
        try await withTemporaryDirectoryAsync { root in
            let drive = root.appending(path: "Drive", directoryHint: .isDirectory)
            let store = BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            try writeFile("a", to: "2024/07/IMG_1.jpg", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:1", paths: ["2024/07/IMG_1.jpg"])], in: drive)

            // The index lists the drive, then pauses before its first file, as if an export had just started.
            let export = ExportStub(isRunning: false)
            export.pausedChecks = [2]
            let browse = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { export.check() })
            browse.update(destination: drive, name: "Drive", isConnected: true)
            for _ in 0..<200 where !browse.isPaused {
                try await Task.sleep(for: .milliseconds(25))
            }

            // The export ends after writing a file the listing didn't see. Refresh asks for another pass.
            try writeFile("b", to: "2024/07/IMG_2.jpg", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:2", paths: ["2024/07/IMG_2.jpg"])], in: drive)
            browse.refresh()
            #expect(browse.isIndexing)
            for _ in 0..<400 where browse.isIndexing {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(browse.isIndexing == false)
            #expect(Set(browse.entries.keys) == ["2024/07/IMG_1.jpg", "2024/07/IMG_2.jpg"])
        }
    }

    @Test @MainActor func refreshWithNoRunningIndexStartsOne() async throws {
        try await withTemporaryDirectoryAsync { root in
            let drive = root.appending(path: "Drive", directoryHint: .isDirectory)
            let store = BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            try writeFile("a", to: "2024/07/IMG_1.jpg", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:1", paths: ["2024/07/IMG_1.jpg"])], in: drive)

            let browse = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false })
            browse.update(destination: drive, name: "Drive", isConnected: true)
            for _ in 0..<200 where browse.isIndexing {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(Set(browse.entries.keys) == ["2024/07/IMG_1.jpg"])

            try writeFile("b", to: "2024/07/IMG_2.jpg", in: drive)
            try ExportManifest.appendRecords([(key: "icloud-id:2", paths: ["2024/07/IMG_2.jpg"])], in: drive)
            browse.refresh()
            #expect(browse.isIndexing)
            for _ in 0..<200 where browse.isIndexing {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(Set(browse.entries.keys) == ["2024/07/IMG_1.jpg", "2024/07/IMG_2.jpg"])
        }
    }

    // MARK: - Dates and sort order

    private func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "BrowseBackupTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    private func dated(_ path: String, _ date: Date?, latitude: Double? = nil, longitude: Double? = nil) -> BrowseEntry {
        BrowseDateFixtures.dated(path, date, latitude: latitude, longitude: longitude)
    }

    @MainActor
    @Test func newModelOpensOnDatesWithTheMostRecentMonthSelectedAndItsYearExpanded() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = BrowseBackup(
            store: BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
            namer: FakeNamer(answers: [:]), isExportRunning: { false },
            calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults
        )
        #expect(browse.mode == .dates)
        browse.load(entries: [
            dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
            dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2)),
        ], destination: URL(filePath: "/tmp/drive"))
        #expect(browse.selectedDateID == "month:2026-10")
        #expect(browse.expandedYears == ["year:2026"])
        #expect(browse.gridPaths == ["2026/10/b.jpg"])
    }

    @MainActor
    @Test func oldestFirstSelectsTheOldestMonth() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = BrowseBackup(
            store: BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
            namer: FakeNamer(answers: [:]), isExportRunning: { false },
            calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults
        )
        browse.sortOrder = .oldestFirst
        browse.load(entries: [
            dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
            dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2)),
        ], destination: URL(filePath: "/tmp/drive"))
        #expect(browse.selectedDateID == "month:2024-07")
    }

    @MainActor
    @Test func automaticSelectionFollowsTheIndexUntilTheUserPicksARow() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let drive = URL(filePath: "/tmp/drive")
        let browse = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false },
                                  calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults)
        let old = dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4))
        let newer = dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2))
        let newest = dated("2027/01/c.jpg", BrowseDateFixtures.instant(2027, 1, 9))

        browse.load(entries: [old], destination: drive)
        #expect(browse.selectedDateID == "month:2024-07")
        browse.load(entries: [old, newer], destination: drive)
        #expect(browse.selectedDateID == "month:2026-10")

        browse.selectedDateID = "month:2024-07"
        browse.load(entries: [old, newer, newest], destination: drive)
        #expect(browse.selectedDateID == "month:2024-07")
    }

    @MainActor
    @Test func aSelectedMonthThatDisappearsFallsBackToTheAutomaticChoice() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = BrowseBackup(store: BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                  namer: FakeNamer(answers: [:]), isExportRunning: { false },
                                  calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults)
        let drive = URL(filePath: "/tmp/drive")
        browse.load(entries: [
            dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
            dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2)),
        ], destination: drive)
        browse.selectedDateID = "month:2024-07"
        browse.load(entries: [dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2))], destination: drive)
        #expect(browse.selectedDateID == "month:2026-10")
    }

    @MainActor
    @Test func changingTheSelectedRowClearsThePhotoSelection() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = BrowseBackup(store: BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                  namer: FakeNamer(answers: [:]), isExportRunning: { false },
                                  calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults)
        browse.load(entries: [
            dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4)),
            dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2)),
        ], destination: URL(filePath: "/tmp/drive"))
        browse.selectedPaths = ["2026/10/b.jpg"]
        browse.selectedDateID = "year:2024"
        #expect(browse.selectedPaths.isEmpty)
        #expect(browse.gridPaths == ["2024/07/a.jpg"])
    }

    @MainActor
    @Test func placesAndMapGridsFollowTheSortOrderWithUndatedLast() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = BrowseBackup(store: BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                  namer: FakeNamer(answers: [:]), isExportRunning: { false },
                                  calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults)
        let rome = PlaceResolver.cellKey(latitude: 41.9028, longitude: 12.4964)
        browse.load(
            entries: [
                dated("2024/07/a.jpg", BrowseDateFixtures.instant(2024, 7, 4), latitude: 41.9028, longitude: 12.4964),
                dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2), latitude: 41.9028, longitude: 12.4964),
                dated("undated/c.jpg", nil, latitude: 41.9028, longitude: 12.4964),
            ],
            names: [rome: PlaceResolver.Place(country: "Italy", city: "Rome")],
            destination: URL(filePath: "/tmp/drive")
        )
        browse.mode = .places
        browse.selectedGroupID = "place:Italy › Rome"
        #expect(browse.gridPaths == ["2026/10/b.jpg", "2024/07/a.jpg", "undated/c.jpg"])
        browse.sortOrder = .oldestFirst
        #expect(browse.gridPaths == ["2024/07/a.jpg", "2026/10/b.jpg", "undated/c.jpg"])

        browse.mode = .map
        browse.mapSelection = [rome]
        #expect(browse.gridPaths == ["2024/07/a.jpg", "2026/10/b.jpg", "undated/c.jpg"])
        browse.sortOrder = .newestFirst
        #expect(browse.gridPaths == ["2026/10/b.jpg", "2024/07/a.jpg", "undated/c.jpg"])
    }

    @MainActor
    @Test func sortOrderIsSavedAndAnUnknownValueFallsBackToNewestFirst() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let first = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false }, defaults: defaults)
        #expect(first.sortOrder == .newestFirst)
        first.sortOrder = .oldestFirst
        let second = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false }, defaults: defaults)
        #expect(second.sortOrder == .oldestFirst)

        defaults.set("sideways", forKey: BrowseSortOrder.defaultsKey)
        let third = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false }, defaults: defaults)
        #expect(third.sortOrder == .newestFirst)
    }

    @MainActor
    @Test func changingTheDestinationResetsTheDateSelectionAndExpansion() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let browse = BrowseBackup(store: BrowseIndexStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                  namer: FakeNamer(answers: [:]), isExportRunning: { false },
                                  calendar: BrowseDateFixtures.calendar("Europe/Rome"), defaults: defaults)
        browse.load(entries: [dated("2026/10/b.jpg", BrowseDateFixtures.instant(2026, 10, 2))], destination: URL(filePath: "/tmp/drive"))
        #expect(browse.selectedDateID != nil)
        browse.update(destination: URL(filePath: "/tmp/other"), name: "Other", isConnected: false)
        #expect(browse.selectedDateID == nil)
        #expect(browse.expandedYears.isEmpty)
    }

    @MainActor
    @Test func indexingBuildsTheDatesInTheBackground() async throws {
        try await withTemporaryDirectoryAsync { root in
            let drive = root.appending(path: "Drive", directoryHint: .isDirectory)
            let store = BrowseIndexStore(directory: root.appending(path: "Index", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            try writeImage(at: drive.appending(path: "2024/07/IMG_1.jpg"), type: UTType.jpeg.identifier, dateTimeOriginal: "2024:07:04 18:30:00")
            try ExportManifest.appendRecords([(key: "icloud-id:1", paths: ["2024/07/IMG_1.jpg"])], in: drive)

            let browse = BrowseBackup(store: store, namer: FakeNamer(answers: [:]), isExportRunning: { false })
            browse.update(destination: drive, name: "Drive", isConnected: true)
            for _ in 0..<200 where browse.isIndexing || browse.isBuildingTimeline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(browse.timeline.years.first?.year == 2024)
            #expect(browse.selectedDateID == "month:2024-07")
        }
    }

    // MARK: - Helpers

    private func located(_ path: String, _ latitude: Double, _ longitude: Double) -> BrowseEntry {
        BrowseEntry(path: path, size: 10, modified: 1, latitude: latitude, longitude: longitude, date: nil, camera: nil)
    }

    private func gps(latitude: Double, longitude: Double) -> [CFString: Any] {
        [
            kCGImagePropertyGPSLatitude: abs(latitude),
            kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude: abs(longitude),
            kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
        ]
    }

    /// Writes an 8 × 8 picture of the given type, with optional GPS, EXIF date and camera.
    private func writeImage(
        at url: URL,
        type: String,
        gps: [CFString: Any]? = nil,
        dateTimeOriginal: String? = nil,
        make: String? = nil,
        model: String? = nil
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())

        var properties: [CFString: Any] = [:]
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        if let dateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal]
        }
        if make != nil || model != nil {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: make ?? "",
                kCGImagePropertyTIFFModel: model ?? "",
            ]
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Answers place lookups from a table, by cell key. Offline, every lookup fails the way a dropped connection does.
struct FakeNamer: PlaceNaming {
    var answers: [String: PlaceResolver.Place]
    var offline = false

    func placeNamed(latitude: Double, longitude: Double) async throws -> PlaceResolver.Place {
        if offline { throw PlaceLookupError.unavailable }
        return answers[PlaceResolver.cellKey(latitude: latitude, longitude: longitude)] ?? PlaceResolver.Place()
    }
}

/// A monotonic clock for the index's save throttle. Each read returns the time, then moves it on by `step`.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval
    private let step: TimeInterval

    init(start: TimeInterval, step: TimeInterval) {
        self.now = start
        self.step = step
    }

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let value = now
        now += step
        return value
    }
}

/// Stands in for the export that the index waits on. `check` is what the index's pause asks, once before the drive is
/// listed and once before each file. `pausedChecks` are check numbers that find an export running.
@MainActor
final class ExportStub {
    var isRunning: Bool
    private(set) var checks = 0
    var pausedChecks: Set<Int> = []

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    func check() -> Bool {
        checks += 1
        return isRunning || pausedChecks.contains(checks)
    }
}

/// Counts reads from the index's metadata callback, which runs off the main actor.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Records how many entries each save held.
final class SaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    var counts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ count: Int) {
        lock.lock()
        values.append(count)
        lock.unlock()
    }
}
