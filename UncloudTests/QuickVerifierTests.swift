import Foundation
import Testing
@testable import Uncloud

@Suite("QuickVerifier")
struct QuickVerifierTests {
    /// Three Photos-library items, one file each, plus one iCloud item with a photo, a movie and a sidecar.
    private func makeBackup(in destination: URL) throws {
        let manifest = try ExportManifest(destination: destination)
        for index in 0..<3 {
            let path = "2024/07/IMG_000\(index).jpg"
            try writeFile("photo \(index)", to: path, in: destination)
            try manifest.recordExport(of: "local\(index)", files: [path])
        }
        try writeFile("live photo", to: "2024/08/IMG_CLOUD.HEIC", in: destination)
        try writeFile("live movie", to: "2024/08/IMG_CLOUD.MOV", in: destination)
        try writeFile("sidecar", to: "2024/08/IMG_CLOUD.xmp", in: destination)
        try manifest.recordExport(
            of: ExportManifest.iCloudIDPrefix + "cloud1",
            files: ["2024/08/IMG_CLOUD.HEIC", "2024/08/IMG_CLOUD.MOV", "2024/08/IMG_CLOUD.xmp"]
        )
        manifest.markRunFinished()
    }

    /// The byte count a download of the cloud item writes: the photo and the movie, not the sidecar.
    private let cloudBytes: Int64 = Int64("live photo".utf8.count + "live movie".utf8.count)

    @Test func cleanBackupHasNoProblems() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            let report = try QuickVerifier.check(destination: destination, catalogSizes: ["cloud1": cloudBytes])
            #expect(report.checkedFiles == 6)
            #expect(report.okItems == 4)
            #expect(report.missingFiles.isEmpty)
            #expect(report.emptyFiles.isEmpty)
            #expect(report.changedFiles.isEmpty)
            #expect(report.sizeMismatchItemIDs.isEmpty)
            #expect(report.problemItemIDs.isEmpty)
            #expect(report.seconds >= 0)
        }
    }

    @Test func missingFileIsFoundAndItsItemIsAProblem() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            try FileManager.default.removeItem(at: destination.appending(path: "2024/07/IMG_0001.jpg"))
            let report = try QuickVerifier.check(destination: destination)
            #expect(report.missingFiles == ["2024/07/IMG_0001.jpg"])
            #expect(report.problemItemIDs == ["local1"])
            #expect(report.okItems == 3)
        }
    }

    @Test func missingFolderMakesItsFilesMissing() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            try FileManager.default.removeItem(at: destination.appending(path: "2024/07"))
            let report = try QuickVerifier.check(destination: destination)
            #expect(report.missingFiles.count == 3)
            #expect(report.problemItemIDs == ["local0", "local1", "local2"])
        }
    }

    @Test func folderInPlaceOfFileIsMissing() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            let path = destination.appending(path: "2024/07/IMG_0002.jpg")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let report = try QuickVerifier.check(destination: destination)
            #expect(report.missingFiles == ["2024/07/IMG_0002.jpg"])
        }
    }

    @Test func zeroByteFileIsEmpty() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            try Data().write(to: destination.appending(path: "2024/07/IMG_0000.jpg"))
            let report = try QuickVerifier.check(destination: destination)
            #expect(report.emptyFiles == ["2024/07/IMG_0000.jpg"])
            #expect(report.missingFiles.isEmpty)
            #expect(report.problemItemIDs == ["local0"])
        }
    }

    @Test func sizeChangedSinceSnapshotIsChanged() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            let entry = try #require(BulkDirectoryLister.list(destination.appending(path: "2024/07")).first { $0.name == "IMG_0002.jpg" })
            var snapshot = FilesSnapshot()
            snapshot.files["2024/07/IMG_0002.jpg"] = FilesSnapshot.FileEntry(size: entry.size + 5, modified: entry.modified)
            try ExportManifest.writeFilesSnapshot(snapshot, in: destination)

            let report = try QuickVerifier.check(destination: destination)
            #expect(report.changedFiles == ["2024/07/IMG_0002.jpg"])
            #expect(report.problemItemIDs == ["local2"])
        }
    }

    @Test func modificationTimeWithinTwoSecondsIsNotAChange() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            let entry = try #require(BulkDirectoryLister.list(destination.appending(path: "2024/07")).first { $0.name == "IMG_0000.jpg" })
            var snapshot = FilesSnapshot()
            snapshot.files["2024/07/IMG_0000.jpg"] = FilesSnapshot.FileEntry(size: entry.size, modified: entry.modified + 1.5)
            snapshot.files["2024/07/IMG_0001.jpg"] = FilesSnapshot.FileEntry(size: 0, modified: entry.modified + 10)
            try ExportManifest.writeFilesSnapshot(snapshot, in: destination)

            let report = try QuickVerifier.check(destination: destination)
            #expect(report.changedFiles == ["2024/07/IMG_0001.jpg"])
        }
    }

    @Test func iCloudItemWhoseFilesDontAddUpIsASizeMismatch() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            // The catalog expects 4 bytes more than what is on disk: a truncated download.
            let report = try QuickVerifier.check(destination: destination, catalogSizes: ["cloud1": cloudBytes + 4])
            #expect(report.sizeMismatchItemIDs == [ExportManifest.iCloudIDPrefix + "cloud1"])
            #expect(report.problemItemIDs == [ExportManifest.iCloudIDPrefix + "cloud1"])
            #expect(report.missingFiles.isEmpty)
        }
    }

    @Test func sidecarIsNotCountedTowardTheSize() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            try writeFile("a much longer sidecar than before", to: "2024/08/IMG_CLOUD.xmp", in: destination)
            let report = try QuickVerifier.check(destination: destination, catalogSizes: ["cloud1": cloudBytes])
            #expect(report.sizeMismatchItemIDs.isEmpty)
        }
    }

    @Test func itemsWithoutCatalogSizesSkipTheSizeCheck() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            let report = try QuickVerifier.check(destination: destination, catalogSizes: [:])
            #expect(report.sizeMismatchItemIDs.isEmpty)
            #expect(report.problemItemIDs.isEmpty)
        }
    }

    @Test func partialICloudItemsAreNotChecked() throws {
        try withTemporaryDirectory { destination in
            try makeBackup(in: destination)
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: ExportManifest.iCloudPartialPrefix + "half", files: ["2024/09/NOPE.jpg"])
            let report = try QuickVerifier.check(destination: destination)
            #expect(report.missingFiles.isEmpty)
            #expect(report.checkedFiles == 6)
        }
    }

    @Test func emptyDestinationHasNothingToCheck() throws {
        try withTemporaryDirectory { destination in
            let report = try QuickVerifier.check(destination: destination)
            #expect(report.checkedFiles == 0)
            #expect(report.okItems == 0)
            #expect(report.problemItemIDs.isEmpty)
        }
    }
}
