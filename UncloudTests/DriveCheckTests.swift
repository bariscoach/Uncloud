import Foundation
import Testing
@testable import Uncloud

/// "Check the drive" against fixture trees: the reconcile rules (plan 2.3) and the counts (plan 2.4).
@Suite("DriveCheck")
struct DriveCheckTests {
    /// Writes `exported.tsv` lines (`key<TAB>path…`) and optional checksums.
    private static func writeManifest(_ records: [(String, [String])], checksums: [String: String] = [:], in destination: URL) throws {
        let folder = destination.appending(path: ".photo-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = records.map { ([$0.0] + $0.1).joined(separator: "\t") + "\n" }.joined()
        try Data(journal.utf8).write(to: folder.appending(path: "exported.tsv"))
        let sums = checksums.map { "\($0.key)\t\($0.value)\n" }.joined()
        try Data(sums.utf8).write(to: folder.appending(path: "checksums.tsv"))
    }

    private static func input(
        _ destination: URL,
        source: LibrarySource = .iCloud,
        layout: FolderLayout = .month,
        selection: LibrarySelection = .everything,
        selectedCount: Int = 10,
        libraryIDs: Set<String>? = nil
    ) -> DriveCheck.Input {
        DriveCheck.Input(destination: destination, source: source, layout: layout, selection: selection,
                         selectedCount: selectedCount, libraryIDs: libraryIDs, setAsideFolder: "session-1")
    }

    private static func exists(_ path: String, in destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.appending(path: path).path(percentEncoded: false))
    }

    @Test func missingFilesAreForgottenSoTheyExportAgain() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("photo a", to: "2024/07/IMG_A.JPG", in: destination)
            try Self.writeManifest([
                ("icloud-id:A", ["2024/07/IMG_A.JPG"]),
                ("icloud-id:B", ["2024/07/IMG_B.JPG", "2024/07/IMG_B.MOV"]),
            ], in: destination)
            try writeFile("photo b", to: "2024/07/IMG_B.JPG", in: destination)

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(report.missingItems == 1)
            #expect(report.missingFiles == ["2024/07/IMG_B.MOV"])
            let records = ExportManifest.records(in: destination)
            #expect(records["icloud-id:A"] != nil)
            #expect(records["icloud-id:B"] == nil)
            #expect(report.onDrive == 1)
            #expect(report.toGo == 9)
            #expect(!report.isApproximate)
            // The photo that's still there stays; only the record goes.
            #expect(Self.exists("2024/07/IMG_B.JPG", in: destination))
        }
    }

    @Test func truncatedFilesAreSetAsideNeverDeletedAndForgotten() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a complete photo", to: "2024/07/IMG_A.JPG", in: destination)
            try writeFile("", to: "2024/07/IMG_EMPTY.JPG", in: destination)
            try writeFile("cut", to: "2024/07/IMG_CUT.JPG", in: destination)
            try Self.writeManifest([
                ("icloud-id:A", ["2024/07/IMG_A.JPG"]),
                ("icloud-id:E", ["2024/07/IMG_EMPTY.JPG"]),
                ("icloud:2024/07/IMG_CUT.JPG", ["2024/07/IMG_CUT.JPG"]),
            ], checksums: ["2024/07/IMG_CUT.JPG": String(repeating: "a", count: 64)], in: destination)
            // The last check saw IMG_CUT.JPG at its full size.
            var snapshot = FilesSnapshot()
            snapshot.files["2024/07/IMG_A.JPG"] = .init(size: 16, modified: 0)
            snapshot.files["2024/07/IMG_CUT.JPG"] = .init(size: 4_000, modified: 0)
            try ExportManifest.writeFilesSnapshot(snapshot, in: destination)

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(report.damagedFiles == ["2024/07/IMG_CUT.JPG", "2024/07/IMG_EMPTY.JPG"])
            #expect(report.setAsideFiles == report.damagedFiles)
            let aside = destination.appending(path: ".photo-export/set-aside/session-1/2024/07")
            #expect(try String(contentsOf: aside.appending(path: "IMG_CUT.JPG"), encoding: .utf8) == "cut")
            #expect(FileManager.default.fileExists(atPath: aside.appending(path: "IMG_EMPTY.JPG").path(percentEncoded: false)))
            #expect(!Self.exists("2024/07/IMG_CUT.JPG", in: destination))
            let records = ExportManifest.records(in: destination)
            #expect(records["icloud:2024/07/IMG_CUT.JPG"] == nil)
            #expect(records["icloud-id:E"] == nil)
            #expect(records["icloud-id:A"] != nil)
            #expect(ExportManifest.checksums(in: destination)["2024/07/IMG_CUT.JPG"] == nil)
            // The new snapshot no longer lists what was moved away.
            let saved = try #require(ExportManifest.filesSnapshot(in: destination))
            #expect(saved.files["2024/07/IMG_CUT.JPG"] == nil)
            #expect(saved.files["2024/07/IMG_A.JPG"] != nil)
            #expect(report.summary.damaged == 2 && report.summary.setAside == 2)
        }
    }

    @Test func anAutomaticCheckOnlyReportsAndLeavesTheDriveUntouched() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a complete photo", to: "2024/07/IMG_A.JPG", in: destination)
            try writeFile("cut", to: "2024/07/IMG_CUT.JPG", in: destination)
            try writeFile("not recorded yet", to: "2024/08/IMG_NEW.JPG", in: destination)
            try Self.writeManifest([
                ("icloud-id:A", ["2024/07/IMG_A.JPG"]),
                ("icloud:2024/07/IMG_CUT.JPG", ["2024/07/IMG_CUT.JPG"]),
                ("icloud-id:GONE", ["2024/07/IMG_GONE.JPG"]),
            ], in: destination)
            var snapshot = FilesSnapshot()
            snapshot.files["2024/07/IMG_CUT.JPG"] = .init(size: 4_000, modified: 0)
            try ExportManifest.writeFilesSnapshot(snapshot, in: destination)
            let folder = destination.appending(path: ".photo-export", directoryHint: .isDirectory)
            let journalBefore = try Data(contentsOf: folder.appending(path: "exported.tsv"))
            let snapshotBefore = try Data(contentsOf: folder.appending(path: "files.tsv"))

            var input = Self.input(destination)
            input.changesDrive = false
            let report = try await DriveCheck.run(input, mode: .full)

            // The problems are reported...
            #expect(report.damagedFiles == ["2024/07/IMG_CUT.JPG"])
            #expect(report.missingFiles == ["2024/07/IMG_GONE.JPG"])
            // ...but nothing on the drive moved, and the records and snapshot are byte-for-byte unchanged.
            #expect(report.setAsideFiles.isEmpty && report.registeredFiles.isEmpty)
            #expect(Self.exists("2024/07/IMG_CUT.JPG", in: destination))
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "set-aside").path(percentEncoded: false)))
            #expect(try Data(contentsOf: folder.appending(path: "exported.tsv")) == journalBefore)
            #expect(try Data(contentsOf: folder.appending(path: "files.tsv")) == snapshotBefore)
        }
    }

    @Test func untrackedDownloadsAreRegisteredBySizeOnlyAndTheUsersOwnFilesNever() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("legacy", to: "2023/01/IMG_OLD.HEIC", in: destination)
            try writeFile("legacy movie", to: "2023/01/IMG_OLD.MOV", in: destination)
            try writeFile("my notes", to: "notes.txt", in: destination)
            try writeFile("doc", to: "Documents/letter.pdf", in: destination)
            try writeFile("half", to: "2023/01/IMG_NEXT.HEIC.part", in: destination)

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(report.registeredFiles == ["2023/01/IMG_OLD.HEIC", "2023/01/IMG_OLD.MOV"])
            #expect(report.otherFiles == 2)
            #expect(report.partialFiles == 1)
            let records = ExportManifest.records(in: destination)
            #expect(records["icloud:2023/01/IMG_OLD.HEIC"] == ["2023/01/IMG_OLD.HEIC"])
            #expect(records.keys.allSatisfy { !$0.contains("notes.txt") && !$0.contains("letter.pdf") })
            // Nothing was hashed during the check.
            #expect(ExportManifest.checksums(in: destination).isEmpty)
            // The Live Photo pair is one item, counted from paths: "about".
            #expect(report.onDrive == 1)
            #expect(report.isApproximate)
            // The snapshot covers everything listed, the user's files included.
            let snapshot = try #require(ExportManifest.filesSnapshot(in: destination))
            #expect(snapshot.files["notes.txt"] != nil)
        }
    }

    @Test func photosLibraryAndFlatFoldersNeverRegisterUntrackedFiles() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("x", to: "2024/07/IMG_1.JPG", in: destination)
            try writeFile("y", to: "IMG_2.JPG", in: destination)
            let photos = try await DriveCheck.run(Self.input(destination, source: .photosLibrary, libraryIDs: []), mode: .full)
            #expect(photos.registeredFiles.isEmpty)
            #expect(photos.otherFiles == 2)

            // In the flat layout only reported paths are ever recorded (plan 7c).
            let flat = try await DriveCheck.run(Self.input(destination, layout: .flat), mode: .full)
            #expect(flat.registeredFiles.isEmpty)
            #expect(flat.otherFiles == 2)
            #expect(ExportManifest.records(in: destination).isEmpty)
        }
    }

    @Test func albumFoldersAreDownloadsOnlyInTheAlbumLayout() {
        #expect(ICloudDownloadPaths.isDownloadPath("Trip/IMG_1.JPG", layout: .album))
        #expect(!ICloudDownloadPaths.isDownloadPath("Trip/IMG_1.JPG", layout: .month))
        #expect(!ICloudDownloadPaths.isDownloadPath("notes.txt", layout: .album))
        #expect(ICloudDownloadPaths.isDownloadPath("2024/07/IMG_1.JPG", layout: .month))
        #expect(!ICloudDownloadPaths.isDownloadPath("2024/7/IMG_1.JPG", layout: .month))
        #expect(!ICloudDownloadPaths.isDownloadPath("2024/07/sub/IMG_1.JPG", layout: .month))
    }

    @Test func livePhotoPairsAndSidecarsCountAsOneItem() {
        let paths = [
            "2024/07/IMG_0001.HEIC", "2024/07/IMG_0001.MOV", "2024/07/IMG_0001.HEIC.xmp",
            "2024/07/IMG_0002.JPG", "2024/07/IMG_0002.JPG.xmp",
            "2024/07/IMG_0003.mov", // a video on its own
            "2024/08/IMG_0001.MOV", // same name, another month: its own item
        ]
        #expect(ICloudItemCount.groupedItemCount(paths: paths) == 4)
    }

    @Test func idRecordsCountExactlyForTheSelectionAndPathRecordsAreGrouped() {
        let records: [String: [String]] = [
            "icloud-id:A": ["2024/07/A.HEIC", "2024/07/A.MOV", "2024/07/A.HEIC.xmp"],
            "icloud-id:B": ["2024/07/B.JPG"],
            "icloud-id:C": ["2024/07/C.JPG"],
            // Also recorded by path by the scanner: not counted twice.
            "icloud:2024/07/A.HEIC": ["2024/07/A.HEIC"],
            "icloud:2024/07/A.MOV": ["2024/07/A.MOV"],
            // Legacy items, by path only.
            "icloud:2023/01/OLD.HEIC": ["2023/01/OLD.HEIC"],
            "icloud:2023/01/OLD.MOV": ["2023/01/OLD.MOV"],
            "icloud:2023/01/OLD.HEIC.xmp": ["2023/01/OLD.HEIC.xmp"],
            // Partly downloaded: never counted.
            "icloud-partial:D": ["2024/07/D.HEIC"],
        ]
        let everything = ICloudItemCount.count(records: records)
        #expect(everything == ICloudItemCount.Count(exact: 3, grouped: 1))
        #expect(everything.isApproximate)

        let only = ICloudItemCount.count(records: records, selection: .only(["A", "D", "Z"]))
        #expect(only == ICloudItemCount.Count(exact: 1, grouped: 0))
        #expect(!only.isApproximate)

        let allExcept = ICloudItemCount.count(records: records, selection: .allExcept(["B"]))
        #expect(allExcept == ICloudItemCount.Count(exact: 2, grouped: 1))

        let onDrive = DriveCheck.onDrive(records: records, source: .iCloud, selection: .only(["A", "B"]),
                                         selectedCount: 2, libraryIDs: nil)
        #expect(onDrive.count == 2 && !onDrive.isApproximate)
    }

    @Test func photosLibraryCountsOnlyItemsStillInTheLibrary() {
        let records: [String: [String]] = [
            "ID-1/L0/001": ["2024/07/a.HEIC"],
            "ID-2/L0/001": ["2024/07/b.HEIC"],
            "ID-GONE/L0/001": ["2024/07/c.HEIC"],
            "icloud:2024/07/x.JPG": ["2024/07/x.JPG"],
        ]
        let counted = DriveCheck.onDrive(records: records, source: .photosLibrary, selection: .allExcept(["ID-2/L0/001"]),
                                         selectedCount: 5, libraryIDs: ["ID-1/L0/001", "ID-2/L0/001", "ID-3/L0/001"])
        #expect(counted.count == 1)
    }

    @Test func partialItemsAreNeitherOnTheDriveNorUntracked() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("photo", to: "2024/07/IMG_LIVE.HEIC", in: destination)
            try writeFile("photo 2", to: "2024/07/IMG_DONE.HEIC", in: destination)
            try writeFile("movie 2", to: "2024/07/IMG_DONE.MOV", in: destination)
            try Self.writeManifest([
                ("icloud-partial:LIVE", ["2024/07/IMG_LIVE.HEIC"]),
                ("icloud-partial:DONE", ["2024/07/IMG_DONE.HEIC"]),
                ("icloud-id:DONE", ["2024/07/IMG_DONE.HEIC", "2024/07/IMG_DONE.MOV"]),
            ], in: destination)

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(report.partialItems == 1)
            #expect(report.partialFiles == 1)
            #expect(report.registeredFiles.isEmpty)
            #expect(report.onDrive == 1)
            let records = ExportManifest.records(in: destination)
            #expect(records["icloud-partial:LIVE"] != nil)
            // Superseded by the later ID record.
            #expect(records["icloud-partial:DONE"] == nil)
        }
    }

    @Test func sidecarsRewrittenWithAnotherSizeAreNotDamaged() {
        let previous = FilesSnapshot.FileEntry(size: 900, modified: 0)
        #expect(!DriveCheck.isDamaged(path: "a/IMG.HEIC.xmp", entry: .init(size: 950, modified: 1), previous: previous))
        #expect(DriveCheck.isDamaged(path: "a/IMG.HEIC.xmp", entry: .init(size: 0, modified: 1), previous: previous))
        #expect(DriveCheck.isDamaged(path: "a/IMG.HEIC", entry: .init(size: 950, modified: 1), previous: previous))
        #expect(!DriveCheck.isDamaged(path: "a/IMG.HEIC", entry: .init(size: 950, modified: 1), previous: nil))
    }

    @Test func aQuickCheckAfterAFullOneSeesTheSameAndChangesNothing() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_A.JPG", in: destination)
            try Self.writeManifest([("icloud-id:A", ["2024/07/IMG_A.JPG"])], in: destination)
            let full = try await DriveCheck.run(Self.input(destination), mode: .full)
            let journal = try Data(contentsOf: destination.appending(path: ".photo-export/exported.tsv"))

            let quick = try await DriveCheck.run(Self.input(destination), mode: .quick)

            #expect(quick.mode == .quick)
            #expect(quick.onDrive == full.onDrive)
            #expect(!quick.foundProblems)
            #expect(try Data(contentsOf: destination.appending(path: ".photo-export/exported.tsv")) == journal)
        }
    }

    @Test func cancellingWhileListingChangesNothing() async throws {
        try await withTemporaryDirectoryAsync { destination in
            for index in 0..<3_000 {
                try writeFile("x", to: "2024/\(String(format: "%02d", index % 12 + 1))/IMG_\(index).JPG", in: destination)
            }
            let task = Task { try await DriveCheck.run(Self.input(destination), mode: .full) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(ExportManifest.records(in: destination).isEmpty)
            #expect(ExportManifest.filesSnapshot(in: destination) == nil)
        }
    }
}
