import Foundation
import Testing
@testable import Uncloud

@Suite("ExportManifest files.tsv snapshot")
struct FilesSnapshotManifestTests {
    private func sample() -> FilesSnapshot {
        FilesSnapshot(
            files: [
                "2024/07/IMG_0001.HEIC": .init(size: 2_483_921, modified: 1_721_000_000.25),
                "notes.txt": .init(size: 0, modified: 1_600_000_000),
            ],
            directories: ["": 1_721_000_100.5, "2024/07": 1_721_000_050.25]
        )
    }

    @Test func snapshotRoundTripsExactly() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            #expect(ExportManifest.filesSnapshot(in: destination) == nil)

            try manifest.writeFilesSnapshot(sample())

            #expect(ExportManifest.filesSnapshot(in: destination) == sample())
        }
    }

    @Test func snapshotIsReplacedAsAWhole() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            var big = FilesSnapshot()
            for index in 0..<500 {
                big.files["2024/07/IMG_\(index).jpg"] = .init(size: Int64(index), modified: Double(index))
            }
            try manifest.writeFilesSnapshot(big)
            try manifest.writeFilesSnapshot(sample())

            // No line of the old snapshot survives, and no temporary file is left next to it.
            #expect(ExportManifest.filesSnapshot(in: destination) == sample())
            let folder = destination.appending(path: ".photo-export")
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            #expect(names.filter { $0.contains("files") }.sorted() == ["files.tsv"])
        }
    }

    @Test func snapshotTextUsesTheDocumentedLines() {
        let text = sample().tsv
        #expect(text.contains("file\t2024/07/IMG_0001.HEIC\t2483921\t1721000000.25\n"))
        #expect(text.contains("dir\t\t1721000100.5\n"))
        #expect(text.contains("dir\t2024/07\t1721000050.25\n"))
        #expect(FilesSnapshot(tsv: text) == sample())
    }

    @Test func unparseableLinesAreSkipped() {
        let text = "file\ta.jpg\t12\t100.0\nfile\tbroken\tnotanumber\t1\ndir\t2024\t\nstray line\nfile\tcut.jpg\t9"
        let snapshot = FilesSnapshot(tsv: text)
        #expect(snapshot.files == ["a.jpg": .init(size: 12, modified: 100)])
        #expect(snapshot.directories.isEmpty)
    }

    @Test func snapshotFromAnInventoryMatchesWhatWasListed() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("notes", to: "notes.txt", in: destination)
            let result = try await DriveInventory.run(destination: destination, mode: .full)

            let manifest = try ExportManifest(destination: destination)
            try manifest.writeFilesSnapshot(result.snapshot)

            #expect(ExportManifest.filesSnapshot(in: destination) == result.snapshot)
        }
    }
}

@Suite("ExportManifest iCloud item records")
struct ICloudItemRecordTests {
    @Test func itemsAreRecordedByAssetIDAndReadBack() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordICloudItem(id: "ABC/L0/001", paths: ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001.MOV"])
            try manifest.recordICloudItem(id: "DEF/L0/001", paths: ["2024/07/IMG_0002.JPG"])

            #expect(ExportManifest.iCloudItems(in: destination) == [
                "ABC/L0/001": ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001.MOV"],
                "DEF/L0/001": ["2024/07/IMG_0002.JPG"],
            ])
            #expect(ExportManifest.records(in: destination)["icloud-id:ABC/L0/001"] == ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001.MOV"])
            #expect(ExportManifest.exportedIDs(in: destination).contains("icloud-id:DEF/L0/001"))
            #expect(manifest.contains("icloud-id:DEF/L0/001"))
        }
    }

    @Test func laterRecordForTheSameIDReplacesTheEarlierOne() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordICloudItem(id: "ABC", paths: ["2024/07/old.jpg"])
            try manifest.recordICloudItem(id: "ABC", paths: ["2024/07/new.jpg"])
            #expect(ExportManifest.iCloudItems(in: destination) == ["ABC": ["2024/07/new.jpg"]])
        }
    }

    @Test func legacyPathRecordsAreNotICloudItems() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordExport(of: "icloud:2024/07/IMG_0001.HEIC", files: ["2024/07/IMG_0001.HEIC"])
            try manifest.recordExport(of: "PHOTO-LOCAL-ID", files: ["2024/07/x.jpg"])
            #expect(ExportManifest.iCloudItems(in: destination).isEmpty)
        }
    }

    @Test func emptyPathListWritesNothing() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordICloudItem(id: "ABC", paths: [])
            #expect(ExportManifest.iCloudItems(in: destination).isEmpty)
        }
    }

    @Test func fieldsThatWouldBreakTheLinesAreRejectedAndNothingIsWritten() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            #expect(throws: ManifestError.unrecordableField) {
                try manifest.recordICloudItem(id: "ABC", paths: ["2024/07/bad\tname.jpg"])
            }
            #expect(throws: ManifestError.unrecordableField) {
                try manifest.recordICloudItem(id: "AB\nC", paths: ["2024/07/ok.jpg"])
            }
            #expect(throws: ManifestError.unrecordableField) {
                try manifest.recordICloudItem(id: "", paths: ["2024/07/ok.jpg"])
            }
            #expect(ExportManifest.iCloudItems(in: destination).isEmpty)
            #expect(ExportManifest.exportedIDs(in: destination).isEmpty)
        }
    }

    @Test func partialLastLineIsNotAnItem() throws {
        try withTemporaryDirectory { destination in
            _ = try ExportManifest(destination: destination)
            let journal = destination.appending(path: ".photo-export/exported.tsv")
            try Data("icloud-id:ABC\t2024/07/IMG_0001.HEIC\nicloud-id:DEF\t2024/07/IMG_0".utf8).write(to: journal)
            #expect(ExportManifest.iCloudItems(in: destination) == ["ABC": ["2024/07/IMG_0001.HEIC"]])
        }
    }
}

@Suite("ExportManifest set-aside")
struct SetAsideTests {
    @Test func movesTheFileIntoTheSessionFolderKeepingItsPath() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("truncated", to: "2024/07/IMG_0001.HEIC", in: destination)

            let moved = try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC"], session: "S1")

            let target = destination.appending(path: ".photo-export/set-aside/S1/2024/07/IMG_0001.HEIC")
            #expect(moved == ["2024/07/IMG_0001.HEIC": target])
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "2024/07/IMG_0001.HEIC").path(percentEncoded: false)))
            #expect(try String(contentsOf: target, encoding: .utf8) == "truncated")
        }
    }

    @Test func sameNameTwiceGetsANumberAndNeverOverwrites() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("first", to: "2024/07/IMG_0001.HEIC", in: destination)
            let first = try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC"], session: "S1")["2024/07/IMG_0001.HEIC"]

            try writeFile("second", to: "2024/07/IMG_0001.HEIC", in: destination)
            let second = try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC"], session: "S1")["2024/07/IMG_0001.HEIC"]

            let folder = destination.appending(path: ".photo-export/set-aside/S1/2024/07")
            #expect(first?.lastPathComponent == "IMG_0001.HEIC")
            #expect(second?.lastPathComponent == "IMG_0001 (1).HEIC")
            #expect(try String(contentsOf: first!, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second!, encoding: .utf8) == "second")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count == 2)
        }
    }

    @Test func existingSetAsideFilesAreNotOverwritten() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("old copy", to: ".photo-export/set-aside/S1/IMG_0001.HEIC", in: destination)
            try writeFile("older copy", to: ".photo-export/set-aside/S1/IMG_0001 (1).HEIC", in: destination)
            try writeFile("new", to: "IMG_0001.HEIC", in: destination)

            let moved = try manifest.setAside(paths: ["IMG_0001.HEIC"], session: "S1")

            #expect(moved["IMG_0001.HEIC"]?.lastPathComponent == "IMG_0001 (2).HEIC")
            let root = destination.appending(path: ".photo-export/set-aside/S1")
            #expect(try String(contentsOf: root.appending(path: "IMG_0001.HEIC"), encoding: .utf8) == "old copy")
            #expect(try String(contentsOf: root.appending(path: "IMG_0001 (1).HEIC"), encoding: .utf8) == "older copy")
        }
    }

    @Test func nameWithoutExtensionGetsANumberToo() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("a", to: "2024/notes", in: destination)
            try writeFile("old", to: ".photo-export/set-aside/S1/2024/notes", in: destination)
            let moved = try manifest.setAside(paths: ["2024/notes"], session: "S1")
            #expect(moved["2024/notes"]?.lastPathComponent == "notes (1)")
        }
    }

    @Test func missingFilesAreSkippedAndNothingIsDeleted() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("keep", to: "2024/07/IMG_0002.HEIC", in: destination)

            let moved = try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0002.HEIC"], session: "S1")

            #expect(Set(moved.keys) == ["2024/07/IMG_0002.HEIC"])
            // Nothing was deleted: the moved file still exists, and no other file was touched.
            #expect(try String(contentsOf: moved["2024/07/IMG_0002.HEIC"]!, encoding: .utf8) == "keep")
        }
    }

    @Test func unsafePathsAndSessionsAreRefusedBeforeAnythingMoves() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try writeFile("mine", to: "2024/07/IMG_0001.HEIC", in: destination)

            #expect(throws: ManifestError.unsafePath("../outside.txt")) {
                try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC", "../outside.txt"], session: "S1")
            }
            #expect(throws: ManifestError.unsafePath("/etc/hosts")) {
                try manifest.setAside(paths: ["/etc/hosts"], session: "S1")
            }
            #expect(throws: ManifestError.unsafePath("2024//x.jpg")) {
                try manifest.setAside(paths: ["2024//x.jpg"], session: "S1")
            }
            #expect(throws: ManifestError.unsafePath("a/b")) {
                try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC"], session: "a/b")
            }
            #expect(throws: ManifestError.unsafePath("")) {
                try manifest.setAside(paths: ["2024/07/IMG_0001.HEIC"], session: "")
            }
            // The first file was not moved when a later path was refused.
            #expect(try String(contentsOf: destination.appending(path: "2024/07/IMG_0001.HEIC"), encoding: .utf8) == "mine")
        }
    }

    /// QC5: a folder on the path that is a symbolic link must not let a set-aside reach outside the destination.
    @Test func setAsideNeverMovesAFileFromOutsideTheDestinationThroughASymlink() throws {
        try withTemporaryDirectory { root in
            let destination = root.appending(path: "dest", directoryHint: .isDirectory)
            let outside = root.appending(path: "outside", directoryHint: .isDirectory)
            try writeFile("not the destination's", to: "07/IMG_0001.HEIC", in: outside)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination.appending(path: "2024"), withDestinationURL: outside)

            _ = try? ExportManifest.setAside(paths: ["2024/07/IMG_0001.HEIC"], session: "S1", in: destination)

            #expect(FileManager.default.fileExists(atPath: outside.appending(path: "07/IMG_0001.HEIC").path(percentEncoded: false)))
        }
    }
}

@Suite("ExportManifest backward compatibility")
struct ManifestCompatibilityTests {
    /// A destination written by an older app version: journal with PhotoKit and legacy `icloud:` records,
    /// checksums, layout, and no files.tsv or icloud-id records.
    private func writeOldManifest(in destination: URL) throws {
        let folder = destination.appending(path: ".photo-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = "PHOTO-1\t2024/07/IMG_0001.HEIC\t2024/07/IMG_0001-live.MOV\n"
            + "icloud:2024/07/IMG_0002.HEIC\t2024/07/IMG_0002.HEIC\n"
        try Data(journal.utf8).write(to: folder.appending(path: "exported.tsv"))
        let checksums = "2024/07/IMG_0002.HEIC\t" + String(repeating: "a", count: 64) + "\n"
        try Data(checksums.utf8).write(to: folder.appending(path: "checksums.tsv"))
        try Data("month".utf8).write(to: folder.appending(path: "layout"))
    }

    @Test func oldManifestsStillReadAsBefore() throws {
        try withTemporaryDirectory { destination in
            try writeOldManifest(in: destination)

            #expect(ExportManifest.exportedIDs(in: destination) == ["PHOTO-1", "icloud:2024/07/IMG_0002.HEIC"])
            #expect(ExportManifest.records(in: destination)["PHOTO-1"] == ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001-live.MOV"])
            #expect(ExportManifest.checksums(in: destination) == ["2024/07/IMG_0002.HEIC": String(repeating: "a", count: 64)])
            #expect(ExportManifest.layout(in: destination) == .month)
            #expect(ExportManifest.filesSnapshot(in: destination) == nil)
            #expect(ExportManifest.iCloudItems(in: destination).isEmpty)
        }
    }

    @Test func oldManifestsCanBeOpenedAndAppendedTo() throws {
        try withTemporaryDirectory { destination in
            try writeOldManifest(in: destination)

            let manifest = try ExportManifest(destination: destination)
            try manifest.recordICloudItem(id: "NEW", paths: ["2024/08/IMG_0003.HEIC"])
            try manifest.recordExport(of: "PHOTO-2", files: ["2024/08/IMG_0004.HEIC"])

            #expect(ExportManifest.iCloudItems(in: destination) == ["NEW": ["2024/08/IMG_0003.HEIC"]])
            #expect(ExportManifest.records(in: destination)["PHOTO-2"] == ["2024/08/IMG_0004.HEIC"])
            #expect(ExportManifest.records(in: destination)["PHOTO-1"] == ["2024/07/IMG_0001.HEIC", "2024/07/IMG_0001-live.MOV"])
        }
    }

    @Test func oldReadersSeeIDRecordsAsOpaqueIDs() throws {
        try withTemporaryDirectory { destination in
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordICloudItem(id: "ABC", paths: ["2024/07/IMG_0001.HEIC"])
            // The line is an ordinary journal line: an ID, then tab-separated paths. Older app versions read it that way.
            let text = try String(contentsOf: destination.appending(path: ".photo-export/exported.tsv"), encoding: .utf8)
            #expect(text == "icloud-id:ABC\t2024/07/IMG_0001.HEIC\n")
            #expect(ExportManifest.exportedIDs(in: destination) == ["icloud-id:ABC"])
        }
    }
}
