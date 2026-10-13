import Foundation
import Testing
@testable import Uncloud

/// QC round 2: the drive check never moves or records the user's own files, never hides a damaged file it
/// couldn't move, and forgetting an iCloud item invalidates the resume point.
@Suite("DriveCheck file safety")
struct DriveCheckFileSafetyTests {
    private static func writeManifest(_ records: [(String, [String])], checksums: [String: String] = [:], in destination: URL) throws {
        let folder = destination.appending(path: ".photo-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = records.map { ([$0.0] + $0.1).joined(separator: "\t") + "\n" }.joined()
        try Data(journal.utf8).write(to: folder.appending(path: "exported.tsv"))
        let sums = checksums.map { "\($0.key)\t\($0.value)\n" }.joined()
        try Data(sums.utf8).write(to: folder.appending(path: "checksums.tsv"))
    }

    private static func input(_ destination: URL, layout: FolderLayout = .month, changesDrive: Bool = true) -> DriveCheck.Input {
        DriveCheck.Input(destination: destination, source: .iCloud, layout: layout, selection: .everything,
                         selectedCount: 10, libraryIDs: nil, setAsideFolder: "session-1", changesDrive: changesDrive)
    }

    private static func exists(_ path: String, in destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.appending(path: path).path(percentEncoded: false))
    }

    private static func writeResumePoint(in destination: URL) throws {
        try writeFile("{\"schema\":1}", to: ".photo-export/resume.json", in: destination)
    }

    private static let digest = String(repeating: "a", count: 64)

    // MARK: - Resume point (defect 1)

    @Test func aDriveCheckThatForgetsAnICloudItemInvalidatesTheResumePoint() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("photo a", to: "2024/07/IMG_A.JPG", in: destination)
            try Self.writeManifest([
                ("icloud-id:A", ["2024/07/IMG_A.JPG"]),
                ("icloud-id:GONE", ["2024/07/IMG_GONE.JPG"]),
            ], in: destination)
            try Self.writeResumePoint(in: destination)

            // An automatic check only reports: the point stays.
            _ = try await DriveCheck.run(Self.input(destination, changesDrive: false), mode: .full)
            #expect(Self.exists(".photo-export/resume.json", in: destination))

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)
            #expect(report.missingItems == 1)
            #expect(!Self.exists(".photo-export/resume.json", in: destination))
            #expect(ICloudResumePoint.load(in: destination) == nil)
        }
    }

    @Test func aDriveCheckThatForgetsNothingKeepsTheResumePoint() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("photo a", to: "2024/07/IMG_A.JPG", in: destination)
            try Self.writeManifest([("icloud-id:A", ["2024/07/IMG_A.JPG"])], in: destination)
            try Self.writeResumePoint(in: destination)
            _ = try await DriveCheck.run(Self.input(destination), mode: .full)
            #expect(Self.exists(".photo-export/resume.json", in: destination))
        }
    }

    @Test func forgettingICloudRecordsInvalidatesTheResumePointAndPhotosRecordsDoNot() throws {
        try withTemporaryDirectory { destination in
            try Self.writeManifest([
                ("PHOTO-1", ["2024/07/IMG_1.HEIC"]),
                ("icloud:2024/07/IMG_2.JPG", ["2024/07/IMG_2.JPG"]),
                ("icloud-id:C", ["2024/07/IMG_3.JPG"]),
            ], in: destination)
            try Self.writeResumePoint(in: destination)

            try ExportManifest.forget(["PHOTO-1"], in: destination)
            #expect(Self.exists(".photo-export/resume.json", in: destination))

            try ExportManifest.forget(["icloud:2024/07/IMG_2.JPG"], in: destination)
            #expect(!Self.exists(".photo-export/resume.json", in: destination))

            try Self.writeResumePoint(in: destination)
            try ExportManifest.forget(["icloud-id:C"], in: destination)
            #expect(!Self.exists(".photo-export/resume.json", in: destination))
            // A key that has no record forgets nothing.
            try Self.writeResumePoint(in: destination)
            try ExportManifest.forget(["icloud-id:NOT-THERE"], in: destination)
            #expect(Self.exists(".photo-export/resume.json", in: destination))
        }
    }

    // MARK: - The user's own files (defect 2)

    @Test func theUsersDocumentsInAMonthFolderAreNeverRecordedOrMoved() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("buy milk", to: "2024/07/notes.txt", in: destination)
            try writeFile("letter", to: "2024/07/letter.docx", in: destination)
            try writeFile("a photo", to: "2024/07/IMG_1.JPG", in: destination)

            let first = try await DriveCheck.run(Self.input(destination), mode: .full)
            #expect(first.registeredFiles == ["2024/07/IMG_1.JPG"])
            #expect(first.otherFiles == 2)

            // Edited between checks: another size.
            try writeFile("buy milk, eggs and a much longer list", to: "2024/07/notes.txt", in: destination)
            try writeFile("a longer letter", to: "2024/07/letter.docx", in: destination)
            let second = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(Self.exists("2024/07/notes.txt", in: destination))
            #expect(Self.exists("2024/07/letter.docx", in: destination))
            #expect(second.setAsideFiles.isEmpty)
            #expect(second.damagedFiles.isEmpty)
            #expect(second.registeredFiles.isEmpty)
            let recorded = Set(ExportManifest.records(in: destination).values.flatMap { $0 })
            #expect(!recorded.contains("2024/07/notes.txt") && !recorded.contains("2024/07/letter.docx"))
            #expect(second.changedFiles == ["2024/07/letter.docx", "2024/07/notes.txt"])
        }
    }

    @Test func theUsersDocumentsInAnAlbumFolderAreNeverRecordedOrMoved() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("day 1: beach", to: "Trips/plan.pdf", in: destination)
            try writeFile("a photo", to: "Trips/IMG_1.HEIC", in: destination)

            let first = try await DriveCheck.run(Self.input(destination, layout: .album), mode: .full)
            #expect(first.registeredFiles == ["Trips/IMG_1.HEIC"])
            #expect(first.otherFiles == 1)

            try writeFile("day 1: beach, day 2: mountains", to: "Trips/plan.pdf", in: destination)
            let second = try await DriveCheck.run(Self.input(destination, layout: .album), mode: .full)

            #expect(Self.exists("Trips/plan.pdf", in: destination))
            #expect(second.setAsideFiles.isEmpty && second.damagedFiles.isEmpty)
            #expect(!Set(ExportManifest.records(in: destination).values.flatMap { $0 }).contains("Trips/plan.pdf"))
            #expect(second.changedFiles == ["Trips/plan.pdf"])
        }
    }

    @Test func aRegisteredFileWithoutAChecksumIsReportedButNeverMovedWhenItChanges() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("cut", to: "2024/07/IMG_X.JPG", in: destination)
            try Self.writeManifest([("icloud:2024/07/IMG_X.JPG", ["2024/07/IMG_X.JPG"])], in: destination)
            var snapshot = FilesSnapshot()
            snapshot.files["2024/07/IMG_X.JPG"] = .init(size: 4_000, modified: 0)
            try ExportManifest.writeFilesSnapshot(snapshot, in: destination)

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(Self.exists("2024/07/IMG_X.JPG", in: destination))
            #expect(report.setAsideFiles.isEmpty && report.damagedFiles.isEmpty)
            #expect(ExportManifest.records(in: destination)["icloud:2024/07/IMG_X.JPG"] != nil)
            #expect(report.changedFiles == ["2024/07/IMG_X.JPG"])
        }
    }

    @Test func aRecordedDownloadWithAChecksumIsStillSetAsideWhenItChanges() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("cut", to: "2024/07/IMG_X.JPG", in: destination)
            try writeFile("cut", to: "2024/07/notes.txt", in: destination)
            try Self.writeManifest([
                ("icloud:2024/07/IMG_X.JPG", ["2024/07/IMG_X.JPG"]),
                // Recorded and hashed by an older scanner, but a document: never moved.
                ("icloud:2024/07/notes.txt", ["2024/07/notes.txt"]),
            ], checksums: ["2024/07/IMG_X.JPG": Self.digest, "2024/07/notes.txt": Self.digest], in: destination)
            var snapshot = FilesSnapshot()
            snapshot.files["2024/07/IMG_X.JPG"] = .init(size: 4_000, modified: 0)
            snapshot.files["2024/07/notes.txt"] = .init(size: 4_000, modified: 0)
            try ExportManifest.writeFilesSnapshot(snapshot, in: destination)

            let report = try await DriveCheck.run(Self.input(destination), mode: .full)

            #expect(report.setAsideFiles == ["2024/07/IMG_X.JPG"])
            #expect(Self.exists("2024/07/notes.txt", in: destination))
            #expect(report.changedFiles == ["2024/07/notes.txt"])
        }
    }

    @Test func onlyMediaAndSidecarsLookLikeDownloads() {
        #expect(ICloudDownloadPaths.isDownloadPath("2024/07/IMG_1.HEIC", layout: .month))
        #expect(ICloudDownloadPaths.isDownloadPath("2024/07/IMG_1.MOV", layout: .month))
        #expect(ICloudDownloadPaths.isDownloadPath("2024/07/IMG_1.HEIC.xmp", layout: .month))
        #expect(ICloudDownloadPaths.isDownloadPath("2024/07/IMG_1.DNG", layout: .month))
        #expect(ICloudDownloadPaths.isDownloadPath("Trips/IMG_1.PNG", layout: .album))
        #expect(!ICloudDownloadPaths.isDownloadPath("2024/07/notes.txt", layout: .month))
        #expect(!ICloudDownloadPaths.isDownloadPath("2024/07/report.pdf", layout: .month))
        #expect(!ICloudDownloadPaths.isDownloadPath("Trips/plan.pdf", layout: .album))
        #expect(!ICloudDownloadPaths.isDownloadPath("Trips/letter.docx", layout: .album))
        #expect(!ICloudDownloadPaths.isDownloadPath("2024/07/noextension", layout: .month))
    }
}
